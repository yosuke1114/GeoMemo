import Foundation
import AppIntents
import WidgetKit

// ウィジェットの「完了」ボタン。このファイルはアプリとウィジェット拡張の両方に入る
// （ウィジェットの Button(intent:) は、その型がウィジェット側にも要るため）。
//
// 実行されるプロセスが 2 通りあるので、どちらでも壊れないようにしてある。
// - アプリのプロセス: 完了を保存し、監視（ジオフェンス）も外す。
// - ウィジェット拡張のプロセス: 拡張は iCloud の権限を持たず、同期の対象の保存先へ書いても
//   他の端末に伝わる保証がない。そのため保存はせず、App Group の「完了待ち」に ID を足すだけにする。
//   ウィジェットは完了待ちを除いて描き、アプリが次に動いたときに保存・監視の停止を行う。

/// 完了待ちの ID（App Group の UserDefaults）。純粋な読み書きだけで、どのスレッドからでも呼べる。
nonisolated struct WidgetCompletionQueue {
    nonisolated static let key = "widgetPendingDoneIDs"
    nonisolated static let appGroupID = "group.com.yokuro.geomemo"

    private let defaults: UserDefaults?

    nonisolated init(defaults: UserDefaults?) { self.defaults = defaults }

    nonisolated static var shared: WidgetCompletionQueue {
        WidgetCompletionQueue(defaults: UserDefaults(suiteName: appGroupID))
    }

    /// 完了待ちの ID。壊れた値は読み飛ばす。
    nonisolated func pending() -> Set<UUID> {
        let raw = defaults?.stringArray(forKey: Self.key) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    nonisolated func enqueue(_ id: UUID) {
        var ids = pending()
        ids.insert(id)
        write(ids)
    }

    /// 保存し終えた分を外す。
    nonisolated func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        write(pending().subtracting(ids))
    }

    private func write(_ ids: Set<UUID>) {
        defaults?.set(ids.map(\.uuidString).sorted(), forKey: Self.key)
    }
}

/// ウィジェットのメモ 1 件を完了にする。ショートカットには出さない（ウィジェット専用）。
struct CompleteMemoFromWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Memo"
    static let description: IntentDescription = "Marks a GeoMemo memo as complete"
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Memo ID")
    var memoID: String

    init() {}

    init(memoID: UUID) {
        self.memoID = memoID.uuidString
    }

    // 呼ばれるスレッドに依存しないよう、MainActor に固定して始める。
    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: memoID) {
            #if WIDGET_EXTENSION
            WidgetCompletionQueue.shared.enqueue(id)
            #else
            WidgetCompletion.applyInApp([id])
            #endif
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

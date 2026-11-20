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
/// ID ごとに別のキーで持つ。1 つの配列を「読んで書く」と、拡張とアプリが同時に動いたときに
/// 片方の追加が消えるため（キーが別なら、互いの書き込みは衝突しない）。
nonisolated struct WidgetCompletionQueue {
    nonisolated static let keyPrefix = "widgetPendingDone."
    nonisolated static let appGroupID = "group.com.yokuro.geomemo"

    private let defaults: UserDefaults?

    nonisolated init(defaults: UserDefaults?) { self.defaults = defaults }

    nonisolated static var shared: WidgetCompletionQueue {
        WidgetCompletionQueue(defaults: UserDefaults(suiteName: appGroupID))
    }

    /// 完了待ちの ID。壊れたキーは読み飛ばす。
    nonisolated func pending() -> Set<UUID> {
        guard let defaults else { return [] }
        var ids: Set<UUID> = []
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            if let id = UUID(uuidString: String(key.dropFirst(Self.keyPrefix.count))) { ids.insert(id) }
        }
        return ids
    }

    nonisolated func enqueue(_ id: UUID) {
        defaults?.set(true, forKey: Self.keyPrefix + id.uuidString)
    }

    /// 保存し終えた分だけを外す（その間に別のプロセスが足した分は残る）。
    nonisolated func remove(_ ids: Set<UUID>) {
        for id in ids { defaults?.removeObject(forKey: Self.keyPrefix + id.uuidString) }
    }
}

/// ウィジェットのメモ 1 件を完了にする。ショートカットには出さない（ウィジェット専用）。
struct CompleteMemoFromWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Memo"
    static let description: IntentDescription = "Marks a GeoMemo memo as complete"
    static var isDiscoverable: Bool { false }
    // スタンバイなどのロック中に、第三者が完了にできないようにする
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

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

/// コントロール（コントロールセンター・ロック画面・アクションボタン）から「新しいメモ」を開く。
/// アプリを前面に出し、アプリ側の `perform` で作成の要求を出す（URL を介さない）。
struct OpenNewMemoIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Memo"
    static let description: IntentDescription = "Open GeoMemo to add a new memo"
    static var openAppWhenRun: Bool { true }
    static var isDiscoverable: Bool { false }
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        NewMemoRequest.post()
        #endif
        return .result()
    }
}

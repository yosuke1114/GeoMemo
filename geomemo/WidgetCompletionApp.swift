import Foundation
import SwiftData
import WidgetKit

// ウィジェットで完了にしたメモを、アプリ側で保存・反映する（アプリだけに入る）。
// 画面（SwiftUI）が作られなくても動くよう、画面に頼らない。アプリ起動時・前面復帰時・領域の入退出時に呼ぶ。

@MainActor
enum WidgetCompletion {
    /// 完了を保存し、監視を外す。保存はアプリのコンテナの `mainContext`（画面の `@Query` と同じ）で行うので、
    /// 通知に頼らなくても画面が更新される。保存できなかった分は完了待ちに残して次の機会に回す。
    @discardableResult
    static func applyInApp(_ ids: Set<UUID>) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        var saved: Set<UUID> = []
        do {
            let context = try GeoMemoStore.sharedContainer().mainContext
            let memos = try context.fetch(FetchDescriptor<GeoMemo>(predicate: #Predicate { ids.contains($0.id) }))
            for memo in memos { memo.isDone = true }
            try context.save()
            // 見つからなかった ID（もう削除済み）も、これ以上待たない
            saved = ids
        } catch {
            return []   // 完了待ちはそのまま残る
        }
        for id in saved {
            let key = id.uuidString
            LocationManager.shared.stopMonitoring(memoID: key)
            LocationManager.shared.stopMonitoringRoute(memoID: key)
        }
        WidgetCompletionQueue.shared.remove(saved)
        WidgetCenter.shared.reloadAllTimelines()
        return saved
    }

    /// ウィジェット拡張が溜めた完了待ちを取り込む。取り込んだ ID を返す。
    @discardableResult
    static func drainPending() -> Set<UUID> {
        let ids = WidgetCompletionQueue.shared.pending()
        guard !ids.isEmpty else { return [] }
        return applyInApp(ids)
    }
}

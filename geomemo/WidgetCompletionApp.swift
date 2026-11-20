import Foundation

// ウィジェットで完了にしたメモを、アプリ側で保存・反映する（アプリだけに入る）。

@MainActor
enum WidgetCompletion {
    /// 完了を保存し、監視を外し、画面にも伝える。保存に失敗した分は完了待ちに残して次の機会に回す。
    static func applyInApp(_ ids: Set<UUID>) {
        var saved: Set<UUID> = []
        for id in ids {
            do {
                try GeoMemoStore.markDone(id: id)
                saved.insert(id)
            } catch {
                WidgetCompletionQueue.shared.enqueue(id)
                continue
            }
            let key = id.uuidString
            LocationManager.shared.stopMonitoring(memoID: key)
            LocationManager.shared.stopMonitoringRoute(memoID: key)
            NotificationCenter.default.post(name: .geoMemoMarkDone, object: key)
        }
        WidgetCompletionQueue.shared.remove(saved)
    }

    /// ウィジェット拡張が溜めた完了待ちを取り込む。アプリが前面に来たとき・領域に入ったときに呼ぶ。
    /// 取り込んだ ID を返す（呼び出し側の画面がまだ古い状態でも、その分は完了として扱える）。
    @discardableResult
    static func drainPending() -> Set<UUID> {
        let ids = WidgetCompletionQueue.shared.pending()
        guard !ids.isEmpty else { return [] }
        applyInApp(ids)
        return ids
    }
}

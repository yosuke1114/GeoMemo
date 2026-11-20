import Testing
import Foundation
@testable import geomemo

// MARK: - ウィジェットの完了待ち

@Suite("WidgetCompletionQueue")
struct WidgetCompletionQueueTests {
    private func makeQueue() -> WidgetCompletionQueue {
        let suite = "widget-completion-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WidgetCompletionQueue(defaults: defaults)
    }

    @Test("最初は空")
    func startsEmpty() {
        #expect(makeQueue().pending().isEmpty)
    }

    @Test("足した ID が読める。同じ ID を 2 回足しても 1 件")
    func enqueueIsIdempotent() {
        let queue = makeQueue()
        let id = UUID()
        queue.enqueue(id)
        queue.enqueue(id)
        #expect(queue.pending() == [id])
    }

    @Test("保存し終えた分だけを外す")
    func removeOnlyGivenIDs() {
        let queue = makeQueue()
        let a = UUID(), b = UUID(), c = UUID()
        [a, b, c].forEach(queue.enqueue)
        queue.remove([a, c])
        #expect(queue.pending() == [b])
        queue.remove([])
        #expect(queue.pending() == [b])
    }

    @Test("壊れたキーは読み飛ばす")
    func ignoresMalformedValues() {
        let suite = "widget-completion-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let good = UUID()
        defaults.set(true, forKey: WidgetCompletionQueue.keyPrefix + "not-a-uuid")
        defaults.set(true, forKey: WidgetCompletionQueue.keyPrefix + good.uuidString)
        defaults.set(true, forKey: "unrelated")
        #expect(WidgetCompletionQueue(defaults: defaults).pending() == [good])
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("別々のキャッシュ（プロセス）が同時に足しても、互いの分が消えない")
    func concurrentWritersDoNotLoseEntries() {
        let suite = "widget-completion-test-\(UUID().uuidString)"
        let a = WidgetCompletionQueue(defaults: UserDefaults(suiteName: suite))
        let b = WidgetCompletionQueue(defaults: UserDefaults(suiteName: suite))
        let x = UUID(), y = UUID()
        a.enqueue(x)
        b.enqueue(y)
        // 先に読んでいた側が、取り込んだ分だけを外しても、あとから足された分は残る
        a.remove([x])
        #expect(b.pending() == [y])
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test("UserDefaults が無ければ何もしない（クラッシュしない）")
    func nilDefaults() {
        let queue = WidgetCompletionQueue(defaults: nil)
        queue.enqueue(UUID())
        #expect(queue.pending().isEmpty)
    }

    @Test("どのスレッドからでも呼べる")
    func callableOffMainThread() async {
        let suite = "widget-completion-test-\(UUID().uuidString)"
        let id = UUID()
        await Task.detached {
            WidgetCompletionQueue(defaults: UserDefaults(suiteName: suite)).enqueue(id)
        }.value
        #expect(WidgetCompletionQueue(defaults: UserDefaults(suiteName: suite)).pending() == [id])
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test("ウィジェットの App Group がアプリ本体と同じ")
    func appGroupMatchesStore() {
        #expect(WidgetCompletionQueue.appGroupID == GeoMemoStore.appGroupID)
    }
}

// MARK: - ディープリンク

@Suite("DeepLinkRoute")
struct DeepLinkRouteTests {
    @Test("メモの URL")
    func memo() {
        let id = UUID()
        #expect(DeepLinkRoute.parse(URL(string: "geomemo://memo/\(id.uuidString)")!) == .memo(id))
    }

    @Test("メモの ID が不正なら無視する")
    func memoInvalid() {
        #expect(DeepLinkRoute.parse(URL(string: "geomemo://memo/xyz")!) == nil)
        #expect(DeepLinkRoute.parse(URL(string: "geomemo://memo")!) == nil)
    }

    @Test("新しいメモ（コントロール・ロック画面から）")
    func newMemo() {
        #expect(DeepLinkRoute.parse(URL(string: "geomemo://new")!) == .newMemo)
    }

    @Test("お気に入り・検索")
    func favoritesAndSearch() {
        #expect(DeepLinkRoute.parse(URL(string: "geomemo://favorites")!) == .favorites)
        #expect(DeepLinkRoute.parse(URL(string: "geomemo://search?q=milk")!) == .search("milk"))
        #expect(DeepLinkRoute.parse(URL(string: "geomemo://search")!) == nil)
    }

    @Test("別の scheme や未知の host は無視する")
    func unknown() {
        #expect(DeepLinkRoute.parse(URL(string: "https://example.com/new")!) == nil)
        #expect(DeepLinkRoute.parse(URL(string: "geomemo://unknown")!) == nil)
    }
}

// MARK: - 新しいメモの要求

@MainActor
@Suite("NewMemoRequest", .serialized)
struct NewMemoRequestTests {
    @Test("要求は 1 回だけ取り出せる")
    func consumeOnce() {
        _ = NewMemoRequest.consume()
        #expect(NewMemoRequest.consume() == false)
        NewMemoRequest.post()
        #expect(NewMemoRequest.isPending)
        #expect(NewMemoRequest.consume() == true)
        #expect(NewMemoRequest.consume() == false)
    }
}

// MARK: - 完了したメモの領域

@Suite("GeofenceReconcilePlanner 完了した領域の回収")
struct GeofenceStaleAfterWidgetDoneTests {
    @Test("ウィジェットで完了にしたメモの領域が登録されたまま残っていても、次の整合で外れる")
    func doneRegionIsStopped() {
        let done = UUID().uuidString
        let live = UUID().uuidString
        let plan = GeofenceReconcilePlanner.plan(
            items: [GeofenceItem(key: live, regionIDs: [live])],
            monitored: [done, live])
        #expect(plan.stopRegionIDs == [done])
        #expect(plan.stop.isEmpty)
        #expect(plan.start.isEmpty)
    }

    @Test("完了したルートの経由地の領域も外れる")
    func doneRouteRegionsAreStopped() {
        let id = UUID().uuidString
        let plan = GeofenceReconcilePlanner.plan(items: [], monitored: ["\(id)|wp|0", "\(id)|wp|1"])
        #expect(plan.stopRegionIDs.count == 2)
    }
}

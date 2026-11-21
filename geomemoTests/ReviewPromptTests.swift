import Testing
import Foundation
@testable import geomemo

// 評価の依頼の頃合いの判断・画面の条件・端末内の記録のテスト。画面・StoreKit には依存しない。

private let day: TimeInterval = 24 * 60 * 60
private let hour: TimeInterval = 60 * 60
private let now = Date(timeIntervalSince1970: 2_000_000_000)

private func eligible(
    done: Int = 0,
    completed: Bool = false,
    lastSuccess: Date? = now,
    lastVersion: String? = nil,
    lastAt: Date? = nil,
    version: String = "1.2"
) -> Bool {
    ReviewPromptPolicy.isEligible(
        doneFromNotificationCount: done,
        hasCompletedRequest: completed,
        lastSuccessAt: lastSuccess,
        lastPromptedVersion: lastVersion,
        lastPromptedAt: lastAt,
        currentVersion: version,
        now: now)
}

@Suite("ReviewPromptPolicy")
struct ReviewPromptPolicyTests {
    @Test func 成功が無ければ出さない() {
        #expect(!eligible())
    }

    @Test func 通知からの完了は3回で候補になる() {
        #expect(!eligible(done: 2))
        #expect(eligible(done: 3))
    }

    @Test func 依頼の完了は1回で候補になる() {
        #expect(eligible(completed: true))
    }

    @Test func 最後の成功から12時間を過ぎたら出さない() {
        #expect(eligible(completed: true, lastSuccess: now.addingTimeInterval(-12 * hour)))
        #expect(!eligible(completed: true, lastSuccess: now.addingTimeInterval(-12 * hour - 1)))
        #expect(!eligible(completed: true, lastSuccess: nil))
    }

    @Test func 同じ版では二度と出さない() {
        #expect(!eligible(done: 3, lastVersion: "1.2", lastAt: now.addingTimeInterval(-400 * day)))
    }

    @Test func 前に出してから120日は空ける() {
        #expect(!eligible(done: 3, lastVersion: "1.1", lastAt: now.addingTimeInterval(-119 * day)))
        #expect(eligible(done: 3, lastVersion: "1.1", lastAt: now.addingTimeInterval(-120 * day)))
    }
}

@Suite("ReviewPromptScreenState")
struct ReviewPromptScreenStateTests {
    private let ready = ReviewPromptScreenState(
        isAppActive: true, isListCoveringMap: false, isAnythingPresented: false, isSearching: false,
        hasPendingArrival: false, isGuidanceVisible: false, hasRequiredPermissions: true)

    @Test func 地図が前面で何も出ていなければ出せる() {
        #expect(ready.canPresentReviewPrompt)
    }

    enum Blocker: CaseIterable, Sendable {
        case listCoveringMap, presented, searching, pendingArrival, guidance
    }

    @Test(arguments: Blocker.allCases)
    func ほかの画面が出ていれば出さない(_ blocker: Blocker) {
        var state = ready
        switch blocker {
        case .listCoveringMap: state.isListCoveringMap = true
        case .presented: state.isAnythingPresented = true
        case .searching: state.isSearching = true
        case .pendingArrival: state.hasPendingArrival = true
        case .guidance: state.isGuidanceVisible = true
        }
        #expect(!state.canPresentReviewPrompt)
    }

    @Test func 前面でない・許可が足りないときは出さない() {
        var inactive = ready
        inactive.isAppActive = false
        #expect(!inactive.canPresentReviewPrompt)
        var noPermission = ready
        noPermission.hasRequiredPermissions = false
        #expect(!noPermission.canPresentReviewPrompt)
    }
}

/// テストごとに別の UserDefaults を作り、終わったら消す。
private final class TemporaryDefaults {
    let name = "ReviewPromptStoreTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    deinit {
        // 作った suite の保存内容を消す（deinit からは Sendable でない `defaults` に触れないので standard 経由）
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    func store(version: String = "1.0") -> ReviewPromptStore {
        ReviewPromptStore(defaults: defaults, currentVersion: version)
    }
}

@Suite("ReviewPromptStore")
struct ReviewPromptStoreTests {
    @Test func 回数を数えて上限で止める() {
        let temp = TemporaryDefaults()
        let store = temp.store()
        for i in 0..<5 { store.recordDoneFromNotification(memoID: "m\(i)", at: now) }
        #expect(store.doneFromNotificationCount == ReviewPromptPolicy.requiredDoneFromNotification)
        #expect(store.isEligible(now: now))
        #expect(!store.isEligible(now: now.addingTimeInterval(13 * hour)))
    }

    @Test func 同じ成功は経路が違っても1回だけ数える() {
        let temp = TemporaryDefaults()
        let store = temp.store()
        #expect(store.recordDoneFromNotification(memoID: "m1", at: now))
        #expect(!store.recordDoneFromNotification(memoID: "m1", at: now))
        #expect(store.doneFromNotificationCount == 1)
        #expect(store.recordCompletedRequest(recordName: "r1", at: now))
        #expect(!store.recordCompletedRequest(recordName: "r1", at: now))
    }

    @Test func 出した後は同じ完了が別の経路で届いても数えない() {
        let temp = TemporaryDefaults()
        let store = temp.store(version: "1.0")
        store.recordCompletedRequest(recordName: "r1", at: now)
        #expect(store.isEligible(now: now))
        store.markPrompted(at: now)
        #expect(store.doneFromNotificationCount == 0)
        #expect(!store.hasCompletedRequest)
        #expect(store.lastSuccessAt == nil)
        #expect(store.lastPromptedVersion == "1.0")
        #expect(store.lastPromptedAt == now)

        // 新しい版・120 日後でも、同じ依頼の完了（通知のタップ・見守りの同期）は数えない
        let later = temp.store(version: "1.1")
        let after = now.addingTimeInterval(200 * day)
        #expect(!later.recordCompletedRequest(recordName: "r1", at: after))
        #expect(!later.isEligible(now: after))
        // 別の依頼の完了なら数える
        #expect(later.recordCompletedRequest(recordName: "r2", at: after))
        #expect(later.isEligible(now: after))
    }

    @Test func 出せない期間の成功は捨てる() {
        let temp = TemporaryDefaults()
        let store = temp.store(version: "1.0")
        store.markPrompted(at: now)
        // 同じ版のうちに 3 回完了しても数えない
        for i in 0..<3 { #expect(!store.recordDoneFromNotification(memoID: "m\(i)", at: now.addingTimeInterval(hour))) }
        #expect(store.doneFromNotificationCount == 0)
        // 版が上がっても 120 日以内なら数えない
        let next = temp.store(version: "1.1")
        #expect(!next.recordDoneFromNotification(memoID: "m9", at: now.addingTimeInterval(30 * day)))
        #expect(next.doneFromNotificationCount == 0)
    }

    @Test func 許可が足りないときは捨てる() {
        let temp = TemporaryDefaults()
        let store = temp.store()
        store.recordCompletedRequest(recordName: "r1", at: now)
        store.discardSuccesses()
        #expect(!store.isEligible(now: now))
    }

    @Test func 覚える識別子は上限まで() {
        let temp = TemporaryDefaults()
        let store = temp.store()
        for i in 0..<(ReviewPromptPolicy.rememberedKeyLimit + 10) {
            store.recordDoneFromNotification(memoID: "m\(i)", at: now)
        }
        #expect(store.countedKeys.count == ReviewPromptPolicy.rememberedKeyLimit)
        #expect(store.countedKeys.first == "memo:m10")
    }

    @Test func 依頼の完了の購読だけを数える() {
        #expect(ReviewPromptStore.completedRequestRecordName(
            subscriptionID: CKShareService.arrivedSubscriptionID, recordName: "r1") == nil)
        #expect(ReviewPromptStore.completedRequestRecordName(subscriptionID: nil, recordName: "r1") == nil)
        #expect(ReviewPromptStore.completedRequestRecordName(
            subscriptionID: CKShareService.completedSubscriptionID, recordName: nil) == nil)
        #expect(ReviewPromptStore.completedRequestRecordName(
            subscriptionID: CKShareService.completedSubscriptionID, recordName: "r1") == "r1")
    }
}

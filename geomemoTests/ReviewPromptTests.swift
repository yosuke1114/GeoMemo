import Testing
import Foundation
@testable import geomemo

// 評価の依頼の頃合いの判断と、端末内の記録のテスト。画面・StoreKit には依存しない。

private let day: TimeInterval = 24 * 60 * 60
private let now = Date(timeIntervalSince1970: 2_000_000_000)

private func eligible(
    done: Int = 0,
    completed: Bool = false,
    lastVersion: String? = nil,
    lastAt: Date? = nil,
    version: String = "1.2"
) -> Bool {
    ReviewPromptPolicy.isEligible(
        doneFromNotificationCount: done,
        hasCompletedRequest: completed,
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

    @Test func 同じ版では二度と出さない() {
        #expect(!eligible(done: 3, lastVersion: "1.2", lastAt: now.addingTimeInterval(-400 * day)))
    }

    @Test func 前に出してから120日は空ける() {
        #expect(!eligible(done: 3, lastVersion: "1.1", lastAt: now.addingTimeInterval(-119 * day)))
        #expect(eligible(done: 3, lastVersion: "1.1", lastAt: now.addingTimeInterval(-120 * day)))
    }
}

@Suite("ReviewPromptStore")
struct ReviewPromptStoreTests {
    private func makeStore() -> ReviewPromptStore {
        let name = "ReviewPromptStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ReviewPromptStore(defaults: defaults)
    }

    @Test func 回数を数えて上限で止める() {
        let store = makeStore()
        for _ in 0..<5 { store.recordDoneFromNotification() }
        #expect(store.doneFromNotificationCount == ReviewPromptPolicy.requiredDoneFromNotification)
        #expect(store.isEligible(currentVersion: "1.0", now: now))
    }

    @Test func 出したら数え直して同じ版では出さない() {
        let store = makeStore()
        store.recordCompletedRequest()
        #expect(store.isEligible(currentVersion: "1.0", now: now))
        store.markPrompted(version: "1.0", at: now)
        #expect(store.doneFromNotificationCount == 0)
        #expect(!store.hasCompletedRequest)
        #expect(store.lastPromptedVersion == "1.0")
        #expect(store.lastPromptedAt == now)
        store.recordCompletedRequest()
        #expect(!store.isEligible(currentVersion: "1.0", now: now.addingTimeInterval(365 * day)))
        #expect(store.isEligible(currentVersion: "1.1", now: now.addingTimeInterval(365 * day)))
    }

    @Test func 依頼の完了の購読だけを記録する() {
        let store = makeStore()
        store.recordIfRequestCompleted(subscriptionID: CKShareService.arrivedSubscriptionID)
        store.recordIfRequestCompleted(subscriptionID: nil)
        #expect(!store.hasCompletedRequest)
        store.recordIfRequestCompleted(subscriptionID: CKShareService.completedSubscriptionID)
        #expect(store.hasCompletedRequest)
    }
}

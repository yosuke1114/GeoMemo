import Foundation

// App Store の評価の依頼（`requestReview`）を出す頃合い。
//
// 「うまくいった直後」にだけ出す。うまくいったと数えるのは次の 2 つ。
// - 到着・退出の通知から「完了」を押して、完了が保存できた（場所の通知が役に立った）
// - 自分が送った依頼が、相手の側で完了になった（初めて分かったとき）
// 前者は 3 回、後者は 1 回で候補にする。出したら数え直し、同じ版では二度と出さず、
// 前に出してから 120 日は空ける（OS 側でも年 3 回までに抑えられる）。
// 許可が足りない人（通知が来ない状態の人）には出さない。その判断は画面側（`MapTabView`）で行う。

/// 出してよいかの判断（純粋な関数。テスト対象）。
nonisolated enum ReviewPromptPolicy {
    /// 通知から「完了」を押した回数が、この回数に届いたら候補にする。
    static let requiredDoneFromNotification = 3
    /// 前に出してから空ける日数。
    static let minimumDaysBetweenPrompts = 120

    static func isEligible(
        doneFromNotificationCount: Int,
        hasCompletedRequest: Bool,
        lastPromptedVersion: String?,
        lastPromptedAt: Date?,
        currentVersion: String,
        now: Date
    ) -> Bool {
        guard doneFromNotificationCount >= requiredDoneFromNotification || hasCompletedRequest else { return false }
        if let lastPromptedVersion, lastPromptedVersion == currentVersion { return false }
        if let lastPromptedAt {
            let interval = TimeInterval(minimumDaysBetweenPrompts) * 24 * 60 * 60
            if now.timeIntervalSince(lastPromptedAt) < interval { return false }
        }
        return true
    }
}

/// 判断の材料の端末内の記録（標準の UserDefaults）。
///
/// 保存するのは回数・フラグ・最後に出した版と日時だけ。メモの内容・場所・相手は保存しない。送信もしない。
/// 通知のデリゲート（main 以外のスレッド）からも呼ぶので MainActor に置かない（UserDefaults はスレッドセーフ）。
nonisolated struct ReviewPromptStore {
    static let doneCountKey = "reviewPrompt.doneFromNotificationCount"
    static let completedRequestKey = "reviewPrompt.hasCompletedRequest"
    static let lastVersionKey = "reviewPrompt.lastPromptedVersion"
    static let lastDateKey = "reviewPrompt.lastPromptedAt"

    static let shared = ReviewPromptStore(defaults: .standard)

    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var doneFromNotificationCount: Int { defaults.integer(forKey: Self.doneCountKey) }
    var hasCompletedRequest: Bool { defaults.bool(forKey: Self.completedRequestKey) }
    var lastPromptedVersion: String? { defaults.string(forKey: Self.lastVersionKey) }
    var lastPromptedAt: Date? {
        guard let value = defaults.object(forKey: Self.lastDateKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// 通知から「完了」を押し、保存できたとき。
    func recordDoneFromNotification() {
        // 数え過ぎても意味がないので上限で止める（読み書きの競合で 1 回ずれても判断は変わらない）
        let next = min(doneFromNotificationCount + 1, ReviewPromptPolicy.requiredDoneFromNotification)
        defaults.set(next, forKey: Self.doneCountKey)
    }

    /// 自分が送った依頼が完了になったと分かったとき。
    func recordCompletedRequest() {
        defaults.set(true, forKey: Self.completedRequestKey)
    }

    /// CloudKit の購読の通知のうち「依頼が完了した」ものなら記録する。
    func recordIfRequestCompleted(subscriptionID: String?) {
        guard subscriptionID == CKShareService.completedSubscriptionID else { return }
        recordCompletedRequest()
    }

    func isEligible(currentVersion: String, now: Date = Date()) -> Bool {
        ReviewPromptPolicy.isEligible(
            doneFromNotificationCount: doneFromNotificationCount,
            hasCompletedRequest: hasCompletedRequest,
            lastPromptedVersion: lastPromptedVersion,
            lastPromptedAt: lastPromptedAt,
            currentVersion: currentVersion,
            now: now)
    }

    /// 出したら記録し、数え直す。
    func markPrompted(version: String, at date: Date = Date()) {
        defaults.set(version, forKey: Self.lastVersionKey)
        defaults.set(date.timeIntervalSince1970, forKey: Self.lastDateKey)
        defaults.set(0, forKey: Self.doneCountKey)
        defaults.set(false, forKey: Self.completedRequestKey)
    }

    /// 今のアプリの版（CFBundleShortVersionString）。
    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}

extension Notification.Name {
    /// 評価の依頼を出せるか確かめてほしいとき（地図の画面が受ける）。
    static let reviewPromptCheck = Notification.Name("geoMemoReviewPromptCheck")
}

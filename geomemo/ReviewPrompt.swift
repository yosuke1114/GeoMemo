import Foundation
import CloudKit

// App Store の評価の依頼（`requestReview`）を出す頃合い。
//
// 「うまくいった直後」にだけ出す。うまくいったと数えるのは次の 2 つ。
// - 到着・退出の通知から「完了」を押して、完了が保存できた（場所の通知が役に立った）
// - 自分が送った依頼が、相手の側で完了になった（初めて分かったとき）
// 前者は 3 回、後者は 1 回で候補にする。候補でいられるのは最後の成功から 12 時間だけ（「直後」）。
// 出したら数え直し、同じ版では二度と出さず、前に出してから 120 日は空ける（OS 側でも年 3 回までに抑えられる）。
// 出せない期間（同じ版・120 日以内）の成功は数えずに捨てる。許可が足りない（通知が来ない）ときも捨てる。
// 同じ成功（同じメモの完了・同じ依頼の完了）は、届く経路が複数あっても 1 回だけ数える。

/// 出してよいかの判断（純粋な関数。テスト対象）。
nonisolated enum ReviewPromptPolicy {
    /// 通知から「完了」を押した回数が、この回数に届いたら候補にする。
    static let requiredDoneFromNotification = 3
    /// 前に出してから空ける日数。
    static let minimumDaysBetweenPrompts = 120
    /// 最後の成功から、候補でいられる時間。
    static let freshness: TimeInterval = 12 * 60 * 60
    /// 数えた成功の識別子を覚えておく数（古いものから捨てる）。
    static let rememberedKeyLimit = 100

    /// 出せない期間か（同じ版で出した・前に出してから 120 日以内）。この間の成功は数えない。
    static func isCoolingDown(lastPromptedVersion: String?, lastPromptedAt: Date?,
                              currentVersion: String, now: Date) -> Bool {
        if let lastPromptedVersion, lastPromptedVersion == currentVersion { return true }
        if let lastPromptedAt {
            let interval = TimeInterval(minimumDaysBetweenPrompts) * 24 * 60 * 60
            if now.timeIntervalSince(lastPromptedAt) < interval { return true }
        }
        return false
    }

    static func isEligible(
        doneFromNotificationCount: Int,
        hasCompletedRequest: Bool,
        lastSuccessAt: Date?,
        lastPromptedVersion: String?,
        lastPromptedAt: Date?,
        currentVersion: String,
        now: Date
    ) -> Bool {
        guard doneFromNotificationCount >= requiredDoneFromNotification || hasCompletedRequest else { return false }
        guard let lastSuccessAt, now.timeIntervalSince(lastSuccessAt) <= freshness else { return false }
        return !isCoolingDown(lastPromptedVersion: lastPromptedVersion, lastPromptedAt: lastPromptedAt,
                              currentVersion: currentVersion, now: now)
    }
}

/// 評価のダイアログを今の画面に重ねてよいか（純粋な関数。テスト対象）。
/// 地図が前面にあり、ほかに何も出ておらず、通知が届く状態のときだけ。
nonisolated struct ReviewPromptScreenState: Equatable {
    /// アプリが前面（`scenePhase == .active` かつ `UIApplication.applicationState == .active`）。
    var isAppActive: Bool
    /// compact 幅でリストが全面に出ている（地図が隠れている）。
    var isListCoveringMap: Bool
    /// 何かのシート・全画面の画面が出ている（地図側・リスト側・設定・見守りを問わない）。
    var isAnythingPresented: Bool
    var isSearching: Bool
    /// 受け取り画面を出す予定がある。
    var hasPendingArrival: Bool
    /// 案内のバナーが出ている。
    var isGuidanceVisible: Bool
    /// 位置（常に・正確）と通知の許可が足りている。
    var hasRequiredPermissions: Bool

    var canPresentReviewPrompt: Bool {
        isAppActive && !isListCoveringMap && !isAnythingPresented && !isSearching
            && !hasPendingArrival && !isGuidanceVisible && hasRequiredPermissions
    }
}

/// 判断の材料の端末内の記録（標準の UserDefaults）。
///
/// 保存するのは回数・フラグ・最後に成功した日時・最後に出した版と日時と、二重に数えないための識別子
/// （メモの UUID・依頼のレコード名。最大 100 件）だけ。メモの内容・場所・相手は保存しない。送信もしない。
/// 通知のデリゲート（main 以外のスレッド）からも呼ぶので MainActor に置かない（UserDefaults はスレッドセーフ。
/// 同時に 2 つ記録されて 1 回分ずれても、判断が少し遅れるだけ）。
nonisolated struct ReviewPromptStore {
    static let doneCountKey = "reviewPrompt.doneFromNotificationCount"
    static let completedRequestKey = "reviewPrompt.hasCompletedRequest"
    static let lastSuccessKey = "reviewPrompt.lastSuccessAt"
    static let countedKeysKey = "reviewPrompt.countedKeys"
    static let lastVersionKey = "reviewPrompt.lastPromptedVersion"
    static let lastDateKey = "reviewPrompt.lastPromptedAt"

    static let shared = ReviewPromptStore(defaults: .standard, currentVersion: currentAppVersion)

    nonisolated(unsafe) private let defaults: UserDefaults
    let currentVersion: String

    init(defaults: UserDefaults, currentVersion: String) {
        self.defaults = defaults
        self.currentVersion = currentVersion
    }

    var doneFromNotificationCount: Int { defaults.integer(forKey: Self.doneCountKey) }
    var hasCompletedRequest: Bool { defaults.bool(forKey: Self.completedRequestKey) }
    var lastSuccessAt: Date? { date(Self.lastSuccessKey) }
    var lastPromptedVersion: String? { defaults.string(forKey: Self.lastVersionKey) }
    var lastPromptedAt: Date? { date(Self.lastDateKey) }
    var countedKeys: [String] { defaults.stringArray(forKey: Self.countedKeysKey) ?? [] }

    /// 通知から「完了」を押し、保存できたとき。数えたら true。
    @discardableResult
    func recordDoneFromNotification(memoID: String, at now: Date = Date()) -> Bool {
        guard remember("memo:\(memoID)", now: now) else { return false }
        // 数え過ぎても意味がないので上限で止める
        let next = min(doneFromNotificationCount + 1, ReviewPromptPolicy.requiredDoneFromNotification)
        defaults.set(next, forKey: Self.doneCountKey)
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastSuccessKey)
        return true
    }

    /// 自分が送った依頼が完了になったと分かったとき（レコード名で 1 回だけ数える）。数えたら true。
    @discardableResult
    func recordCompletedRequest(recordName: String, at now: Date = Date()) -> Bool {
        guard remember("request:\(recordName)", now: now) else { return false }
        defaults.set(true, forKey: Self.completedRequestKey)
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastSuccessKey)
        return true
    }

    func isEligible(now: Date = Date()) -> Bool {
        ReviewPromptPolicy.isEligible(
            doneFromNotificationCount: doneFromNotificationCount,
            hasCompletedRequest: hasCompletedRequest,
            lastSuccessAt: lastSuccessAt,
            lastPromptedVersion: lastPromptedVersion,
            lastPromptedAt: lastPromptedAt,
            currentVersion: currentVersion,
            now: now)
    }

    /// 出したら記録し、数え直す（数えた識別子は残し、同じ成功が別の経路で届いても数えない）。
    func markPrompted(at date: Date = Date()) {
        defaults.set(currentVersion, forKey: Self.lastVersionKey)
        defaults.set(date.timeIntervalSince1970, forKey: Self.lastDateKey)
        discardSuccesses()
    }

    /// 数えた成功を捨てる（許可が足りず出せなかったとき・出した後）。
    func discardSuccesses() {
        defaults.set(0, forKey: Self.doneCountKey)
        defaults.set(false, forKey: Self.completedRequestKey)
        defaults.removeObject(forKey: Self.lastSuccessKey)
    }

    /// 識別子を覚える。出せない期間・数え済みなら false（覚えるだけで数えない）。
    private func remember(_ key: String, now: Date) -> Bool {
        var keys = countedKeys
        guard !keys.contains(key) else { return false }
        keys.append(key)
        if keys.count > ReviewPromptPolicy.rememberedKeyLimit {
            keys.removeFirst(keys.count - ReviewPromptPolicy.rememberedKeyLimit)
        }
        defaults.set(keys, forKey: Self.countedKeysKey)
        return !ReviewPromptPolicy.isCoolingDown(
            lastPromptedVersion: lastPromptedVersion, lastPromptedAt: lastPromptedAt,
            currentVersion: currentVersion, now: now)
    }

    private func date(_ key: String) -> Date? {
        guard let value = defaults.object(forKey: key) as? Double else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// 今のアプリの版（CFBundleShortVersionString）。
    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 地図の画面に、評価の依頼を出せるか確かめてもらう。`delay` は出すまでの待ち（秒）。
    static func requestCheck(delay: Double = ReviewPromptCheck.defaultDelay) {
        Task { @MainActor in
            NotificationCenter.default.post(name: .reviewPromptCheck, object: nil,
                                            userInfo: [ReviewPromptCheck.delayKey: delay])
        }
    }
}

nonisolated extension ReviewPromptStore {
    /// CloudKit の購読の通知が「送った依頼が完了した」もので、レコード名が分かれば、それを返す。
    static func completedRequestRecordName(subscriptionID: String?, recordName: String?) -> String? {
        guard subscriptionID == CKShareService.completedSubscriptionID,
              let recordName, !recordName.isEmpty else { return nil }
        return recordName
    }

    /// 「依頼が完了した」購読の通知なら、そのレコードで記録する。数えたら true。
    @discardableResult
    func recordIfRequestCompleted(_ notification: CKNotification?) -> Bool {
        guard let name = Self.completedRequestRecordName(
            subscriptionID: notification?.subscriptionID,
            recordName: (notification as? CKQueryNotification)?.recordID?.recordName) else { return false }
        return recordCompletedRequest(recordName: name)
    }
}

nonisolated enum ReviewPromptCheck {
    static let delayKey = "delay"
    /// 完了の触覚・案内の更新と重ねない待ち。
    static let defaultDelay: Double = 2
    /// 前面で通知のバナーを出した直後（バナーが消えるのを待つ）。
    static let afterBannerDelay: Double = 6
}

extension Notification.Name {
    /// 評価の依頼を出せるか確かめてほしいとき（地図の画面が受ける）。
    static let reviewPromptCheck = Notification.Name("geoMemoReviewPromptCheck")
}

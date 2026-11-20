import Foundation
import UserNotifications
import CloudKit
import Combine

extension Notification.Name {
    static let geoMemoMarkDone          = Notification.Name("geoMemoMarkDone")
}

class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    // MARK: - Category / Action identifiers
    static let categoryID     = "GEOMEMO_ALERT"
    static let actionDone     = "DONE"
    static let actionSnooze5  = "SNOOZE_5"
    static let actionSnooze30 = "SNOOZE_30"

    /// 通知の許可状態。システムから読み込むまでは nil（「未設定」と取り違えないため）。
    @Published var authorizationStatus: UNAuthorizationStatus?
    /// 通知の出し方（バナー・ロック画面・時刻指定要約）。読み込むまでは nil。「通知のチェック」で使う。
    @Published var presentation: NotificationPresentation?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        checkAuthorizationStatus()
    }

    // MARK: - Category / Action identifiers (Friend)
    static let categoryFriendAlert = "FRIEND_ALERT"

    // MARK: - Category Registration (call once at app launch)

    static func registerCategories() {
        // 通常メモカテゴリ
        let done = UNNotificationAction(
            identifier: actionDone,
            title: String(localized: "Complete"),
            // ロック中に第三者が完了にできないよう、解除を求める（スヌーズはそのまま）
            options: [.destructive, .authenticationRequired]
        )
        let snooze5 = UNNotificationAction(
            identifier: actionSnooze5,
            title: String(localized: "5 min later"),
            options: []
        )
        let snooze30 = UNNotificationAction(
            identifier: actionSnooze30,
            title: String(localized: "30 min later"),
            options: []
        )
        let memoCategory = UNNotificationCategory(
            identifier: categoryID,
            actions: [done, snooze5, snooze30],
            intentIdentifiers: [],
            options: []
        )

        // フレンド通知カテゴリ（発火通知・完了通知・未発火アラート）
        let friendCategory = UNNotificationCategory(
            identifier: categoryFriendAlert,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current()
            .setNotificationCategories([memoCategory, friendCategory])
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run { self.authorizationStatus = granted ? .authorized : .denied }
            // 通知の出し方（バナー・ロック画面など）も許可の直後に読み直す
            checkAuthorizationStatus()
            return granted
        } catch {
            print("Notification authorization error: \(error.localizedDescription)")
            return false
        }
    }

    func checkAuthorizationStatus() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let presentation = NotificationPresentation(settings)
            await MainActor.run {
                self.authorizationStatus = settings.authorizationStatus
                self.presentation = presentation
            }
        }
    }

    // MARK: - Diagnostic test notification

    nonisolated static let testNotificationID = "geomemo-diagnostic-test"

    /// 「通知のチェック」のテスト通知。5 秒後に 1 通だけ届ける。
    /// アプリ内の通知スイッチ（isNotificationsEnabled）は見ない（OS 側の経路を確かめるため）。
    /// カテゴリ・userInfo は付けない（「完了」「5 分後」のアクションを出さず、タップしても何も起きない）。
    /// 「最後に通知を出した時刻」には記録しない。
    func sendTestNotification() async -> TestNotificationResult {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard NotificationAccess(settings.authorizationStatus) == .allowed else { return .notAuthorized }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "GeoMemo test alert")
        content.body = String(localized: "If you can see this, alerts are set up to arrive.")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.testNotificationID, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
        // 前回の分が通知センターに残っていると、届いていないのに「届いた」と判定してしまう
        center.removeDeliveredNotifications(withIdentifiers: [Self.testNotificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.testNotificationID])
        let sentAt = Date()
        TestNotificationProbe.shared.reset()
        do {
            try await center.add(request)
        } catch {
            print("Error scheduling test notification: \(error.localizedDescription)")
            return .failed
        }
        // 届いたら通知センターに入る（集中モード中でも入る）。バナーが出たかどうかはアプリからは分からない。
        try? await Task.sleep(for: .seconds(7))
        // アプリが表示の通知を受けた（フォアグラウンド: willPresent、タップ: didReceive）時刻を優先し、
        // 通知センターに入っているか（送信以降のものだけ）を補助にする。
        let deliveredDates = await center.deliveredNotifications()
            .filter { $0.request.identifier == Self.testNotificationID }
            .map(\.date)
        return TestNotificationResult.decide(
            presentedAt: TestNotificationProbe.shared.presentedAt, deliveredDates: deliveredDates, sentAt: sentAt)
    }

    /// ユーザがアプリ内で通知を有効にしているか。未設定は true（オプトアウト方式）。
    private var isNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
    }

    // MARK: - Schedule

    func scheduleImmediateNotification(title: String, body: String, memoID: String) async {
        guard isNotificationsEnabled else { return }
        let content = makeContent(title: title, body: body, memoID: memoID,
                                  defaultBody: String(localized: "You entered the area"))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        await addRequest(UNNotificationRequest(identifier: "geomemo-\(memoID)", content: content, trigger: trigger))
    }

    // MARK: - Dwell Time Notification

    func scheduleDwellNotification(title: String, body: String, memoID: String, dwellMinutes: Int) async {
        guard isNotificationsEnabled else { return }
        let content = makeContent(title: title, body: body, memoID: memoID,
                                  defaultBody: String(localized: "You've been here for a while"))
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(max(1, dwellMinutes * 60)), repeats: false)
        await addRequest(UNNotificationRequest(identifier: "geomemo-dwell-\(memoID)", content: content, trigger: trigger))
    }

    // MARK: - Shared Memo Notifications

    /// 共有メモ発火時に受信者へ表示するローカル通知
    func scheduleSharedMemoFiredNotification(memoTitle: String, requesterName: String, sharedID: String) async {
        guard isNotificationsEnabled else { return }
        let title = memoTitle.isEmpty ? String(localized: "到着しました") : memoTitle
        let name = requesterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let body  = name.isEmpty
            ? String(localized: "We let the person who sent the request know you arrived.")
            : String(format: String(localized: "We let %@ know you arrived."), name)
        let content = makeContent(title: title, body: body, memoID: sharedID,
                                  defaultBody: body, categoryIdentifier: Self.categoryFriendAlert)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        await addRequest(UNNotificationRequest(
            identifier: "shared-fired-\(sharedID)", content: content, trigger: trigger))
    }

    /// 滞在時間トリガー通知をキャンセルする（退場時に呼ぶ）
    func cancelDwellNotification(memoID: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["geomemo-dwell-\(memoID)"])
    }

    // MARK: - Exit Delay Notification

    /// - Parameters:
    ///   - delayMinutes: nil または 0 = 即通知、正値 = 退出からN分後
    func scheduleExitNotification(title: String, body: String, memoID: String, delayMinutes: Int?) async {
        guard isNotificationsEnabled else { return }
        let content = makeContent(title: title, body: body, memoID: memoID,
                                  defaultBody: String(localized: "You left the area"))
        let delay = delayMinutes.map { max(1, $0 * 60) } ?? 1
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(delay), repeats: false)
        await addRequest(UNNotificationRequest(identifier: "geomemo-exit-\(memoID)", content: content, trigger: trigger))
    }

    private func scheduleSnooze(title: String, body: String, memoID: String, minutes: Int) async {
        guard isNotificationsEnabled else { return }
        let content = makeContent(title: title, body: body, memoID: memoID,
                                  defaultBody: String(localized: "You entered the area"))
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(minutes * 60), repeats: false)
        // identifier を memoID で固定して、連打スヌーズが N 個積み上がるのを防ぐ。
        // UNUserNotificationCenter.add は同一 identifier の既存リクエストを置換する。
        await addRequest(UNNotificationRequest(
            identifier: "geomemo-snooze-\(memoID)", content: content, trigger: trigger))
    }

    // MARK: - Private Helpers

    private func makeContent(
        title: String, body: String, memoID: String, defaultBody: String,
        categoryIdentifier: String = NotificationManager.categoryID
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.isEmpty ? defaultBody : body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = ["memoID": memoID, "title": title, "body": body]
        return content
    }

    private func addRequest(_ request: UNNotificationRequest) async {
        do {
            try await UNUserNotificationCenter.current().add(request)
            // 「最後に通知を出した時刻」は、すぐ出す通知だけ記録する（滞在・退出の遅延やスヌーズは予約であって、
            // 出した時刻ではない）。
            if let trigger = request.trigger as? UNTimeIntervalNotificationTrigger, trigger.timeInterval <= 5 {
                DiagnosticsLog.shared.recordNotification()
            }
        } catch {
            print("Error scheduling notification: \(error.localizedDescription)")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    // 完了ハンドラ版を `nonisolated` で実装する。
    // - UNUserNotificationCenter はデリゲートを main 以外のキューから呼ぶことがある。MainActor 隔離の
    //   メソッドとして実装すると、Swift 6 の実行時の隔離チェックで落ちる。
    // - async 版は過去に "Call must be made on main thread" で落ちた報告があるため使わない。
    // 完了ハンドラは SDK 上 @Sendable なので、MainActor へ移ってから呼べる。

    /// フォアグラウンド中も通知バナーを表示
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        // 「通知のチェック」のテスト通知は、受けたことを記録し、通知センターにも残す（.list）。
        if notification.request.identifier == NotificationManager.testNotificationID {
            TestNotificationProbe.shared.markPresented()
            completionHandler([.banner, .list, .sound])
            return
        }
        // 旧版の購読（-v1）の通知は出さない。同じ Apple ID の旧版の端末が作り直した購読で、
        // -v2 と二重に届き、通知文に相手が書いた名前が入る。受けたら -v1 を消す。
        let ckNotification = CKNotification(fromRemoteNotificationDictionary: notification.request.content.userInfo)
        if RequesterSubscriptionPolicy.isLegacy(ckNotification?.subscriptionID) {
            completionHandler([])
            Task { @MainActor in
                try? await CKShareService.shared.ensureRequesterSubscriptions()
            }
            return
        }
        completionHandler([.banner, .sound])
    }

    /// 通知アクションのハンドリング
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        if response.notification.request.identifier == NotificationManager.testNotificationID {
            TestNotificationProbe.shared.markPresented()
            completionHandler()
            return
        }
        let userInfo = response.notification.request.content.userInfo
        let memoID   = userInfo["memoID"]  as? String ?? ""
        let title    = userInfo["title"]   as? String ?? ""
        let body     = userInfo["body"]    as? String ?? ""
        let action   = response.actionIdentifier
        Task { @MainActor in
            await self.handleNotificationAction(action, memoID: memoID, title: title, body: body)
            completionHandler()
        }
    }

    private func handleNotificationAction(_ action: String, memoID: String, title: String, body: String) async {
        switch action {
        case Self.actionDone:
            // 画面に頼らず、保存・監視の停止まで行う（画面へは触覚・案内の更新だけを通知する）
            RegionEventService.shared.markDone(id: memoID)

        case Self.actionSnooze5:
            await scheduleSnooze(title: title, body: body, memoID: memoID, minutes: 5)

        case Self.actionSnooze30:
            await scheduleSnooze(title: title, body: body, memoID: memoID, minutes: 30)

        default:
            // 通知タップ → アプリをフォアグラウンドに
            if !memoID.isEmpty, let uuid = UUID(uuidString: memoID) {
                NotificationCenter.default.post(name: .openGeoMemo, object: uuid)
            }
        }
    }
}

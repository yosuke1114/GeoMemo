import Foundation
import UserNotifications
import Combine

extension Notification.Name {
    static let geoMemoMarkDone          = Notification.Name("geoMemoMarkDone")
    static let openFriendInvitation     = Notification.Name("openFriendInvitation")
    static let didEnterSharedMemoRegion = Notification.Name("didEnterSharedMemoRegion")
}

class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    // MARK: - Category / Action identifiers
    static let categoryID     = "GEOMEMO_ALERT"
    static let actionDone     = "DONE"
    static let actionSnooze5  = "SNOOZE_5"
    static let actionSnooze30 = "SNOOZE_30"

    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

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
            options: .destructive
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
            return granted
        } catch {
            print("Notification authorization error: \(error.localizedDescription)")
            return false
        }
    }

    func checkAuthorizationStatus() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run { self.authorizationStatus = settings.authorizationStatus }
        }
    }

    // MARK: - Schedule

    func scheduleImmediateNotification(title: String, body: String, memoID: String) async {
        let enabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        guard enabled else { return }
        let content = makeContent(title: title, body: body, memoID: memoID,
                                  defaultBody: String(localized: "You entered the area"))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        await addRequest(UNNotificationRequest(identifier: "geomemo-\(memoID)", content: content, trigger: trigger))
    }

    // MARK: - Dwell Time Notification

    func scheduleDwellNotification(title: String, body: String, memoID: String, dwellMinutes: Int) async {
        let enabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        guard enabled else { return }
        let content = makeContent(title: title, body: body, memoID: memoID,
                                  defaultBody: String(localized: "You've been here for a while"))
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(max(1, dwellMinutes * 60)), repeats: false)
        await addRequest(UNNotificationRequest(identifier: "geomemo-dwell-\(memoID)", content: content, trigger: trigger))
    }

    // MARK: - Shared Memo Notifications

    /// 共有メモ発火時に受信者へ表示するローカル通知
    func scheduleSharedMemoFiredNotification(memoTitle: String, requesterName: String, sharedID: String) async {
        let title = memoTitle.isEmpty ? String(localized: "到着しました") : memoTitle
        let body  = requesterName + String(localized: "への到着を通知しました")
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
        let enabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        guard enabled else { return }
        let content = makeContent(title: title, body: body, memoID: memoID,
                                  defaultBody: String(localized: "You left the area"))
        let delay = delayMinutes.map { max(1, $0 * 60) } ?? 1
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(delay), repeats: false)
        await addRequest(UNNotificationRequest(identifier: "geomemo-exit-\(memoID)", content: content, trigger: trigger))
    }

    private func scheduleSnooze(title: String, body: String, memoID: String, minutes: Int) async {
        let content = makeContent(title: title, body: body, memoID: memoID,
                                  defaultBody: String(localized: "You entered the area"))
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(minutes * 60), repeats: false)
        await addRequest(UNNotificationRequest(
            identifier: "geomemo-snooze-\(memoID)-\(UUID().uuidString)", content: content, trigger: trigger))
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
        } catch {
            print("Error scheduling notification: \(error.localizedDescription)")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// フォアグラウンド中も通知バナーを表示
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 通知アクションのハンドリング
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let memoID   = userInfo["memoID"]  as? String ?? ""
        let title    = userInfo["title"]   as? String ?? ""
        let body     = userInfo["body"]    as? String ?? ""

        switch response.actionIdentifier {
        case Self.actionDone:
            NotificationCenter.default.post(name: .geoMemoMarkDone, object: memoID)

        case Self.actionSnooze5:
            Task { await scheduleSnooze(title: title, body: body, memoID: memoID, minutes: 5) }

        case Self.actionSnooze30:
            Task { await scheduleSnooze(title: title, body: body, memoID: memoID, minutes: 30) }

        default:
            // 通知タップ → アプリをフォアグラウンドに
            if !memoID.isEmpty, let uuid = UUID(uuidString: memoID) {
                NotificationCenter.default.post(name: .openGeoMemo, object: uuid)
            }
        }

        completionHandler()
    }
}

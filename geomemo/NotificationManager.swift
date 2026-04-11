import Foundation
import UserNotifications
import Combine

extension Notification.Name {
    static let geoMemoMarkDone = Notification.Name("geoMemoMarkDone")
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

    // MARK: - Category Registration (call once at app launch)

    static func registerCategories() {
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
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [done, snooze5, snooze30],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
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

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.isEmpty ? String(localized: "You entered the area") : body
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["memoID": memoID, "title": title, "body": body]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "geomemo-\(memoID)",
            content: content,
            trigger: trigger
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("Error scheduling notification: \(error.localizedDescription)")
        }
    }

    // MARK: - Exit Delay Notification

    /// 退出後タイマー通知をスケジュールする
    /// - Parameters:
    ///   - delayMinutes: nil または 0 = 即通知、正値 = 退出からN分後
    func scheduleExitNotification(title: String, body: String, memoID: String, delayMinutes: Int?) async {
        let enabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        guard enabled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.isEmpty ? String(localized: "You left the area") : body
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["memoID": memoID, "title": title, "body": body]

        let delay = delayMinutes.map { max(1, $0 * 60) } ?? 1
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(delay), repeats: false)
        let request = UNNotificationRequest(
            identifier: "geomemo-exit-\(memoID)",
            content: content,
            trigger: trigger
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("Error scheduling exit notification: \(error.localizedDescription)")
        }
    }

    private func scheduleSnooze(title: String, body: String, memoID: String, minutes: Int) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.isEmpty ? String(localized: "You entered the area") : body
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["memoID": memoID, "title": title, "body": body]

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(minutes * 60),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: "geomemo-snooze-\(memoID)-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("Error scheduling snooze: \(error.localizedDescription)")
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

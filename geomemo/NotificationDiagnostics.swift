import Foundation
import UserNotifications

// 「通知のチェック」の判定と文言の選択（純粋なロジック。画面・システム API には依存しない）。
// 許可まわりの判定と文言は PermissionGuidance.swift / MapGuidanceBanner.swift（地図のバナー）のものを使う。
// プロジェクトは SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor なので、ここの型は nonisolated にする。

/// App のバックグラウンド更新の状態（UIBackgroundRefreshStatus を画面側で変換して渡す）。
nonisolated enum BackgroundRefreshAccess: Equatable {
    case available, denied, restricted
}

/// 通知の出し方（UNNotificationSettings から画面側で変換して渡す）。
nonisolated struct NotificationPresentation: Equatable {
    /// ロック画面・通知センター・バナーのどれかがオン。
    var showsAnywhere: Bool
    /// 時刻指定要約に入っている（通知があとでまとめて届く）。
    var isInScheduledSummary: Bool

    init(showsAnywhere: Bool, isInScheduledSummary: Bool) {
        self.showsAnywhere = showsAnywhere
        self.isInScheduledSummary = isInScheduledSummary
    }

    init(_ settings: UNNotificationSettings) {
        let shows = [settings.alertSetting, settings.lockScreenSetting, settings.notificationCenterSetting]
            .contains(.enabled)
        self.init(showsAnywhere: shows, isInScheduledSummary: settings.scheduledDeliverySetting == .enabled)
    }
}

nonisolated struct DiagnosticInput: Equatable {
    var permissions: PermissionSnapshot
    /// 通知設定を読めていない間は nil。
    var presentation: NotificationPresentation?
    var inAppNotificationsEnabled: Bool
    var backgroundRefresh: BackgroundRefreshAccess
    var isLowPowerMode: Bool
    /// 監視したい数。
    var requiredRegions: Int
    /// 実際に登録されている数。
    var monitoredRegions: Int
    /// この端末が場所の監視（ジオフェンス）に対応しているか。
    var isMonitoringAvailable: Bool = true
}

nonisolated enum DiagnosticSeverity: Int, Comparable {
    case ok, info, warning, problem

    static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated enum DiagnosticItemID: String, CaseIterable {
    case locationAccess, preciseLocation, notificationPermission, presentation,
         scheduledSummary, inAppSwitch, backgroundRefresh, lowPowerMode, focus, monitoredPlaces
}

nonisolated enum DiagnosticAction: Equatable {
    /// 地図のバナーと同じ動作（許可のダイアログ・設定アプリ）。
    case permission(PermissionNotice.Action)
    case openNotificationSettings
    case enableInAppNotifications
    case reRegisterGeofences
}

nonisolated enum MonitoredPlacesState: Equatable {
    case unsupported
    case notAuthorized
    /// `nearLimitUsed` は上限に近いときだけ入る（補足を出す）。
    case ok(monitored: Int, nearLimitUsed: Int?)
    case overLimit(required: Int, unmonitored: Int)
    case underRegistered(monitored: Int, required: Int)
}

nonisolated struct DiagnosticItem: Equatable, Identifiable {
    let id: DiagnosticItemID
    let severity: DiagnosticSeverity
    /// 1〜3 行目。地図のバナーの題・本文・ボタンを引く。
    let notice: PermissionNotice?
    /// 10 行目。
    let places: MonitoredPlacesState?
    let action: DiagnosticAction?
    /// 状態をまだ読み込めていない（問題に数えない）。
    let isChecking: Bool

    init(id: DiagnosticItemID, severity: DiagnosticSeverity, notice: PermissionNotice? = nil,
         places: MonitoredPlacesState? = nil, action: DiagnosticAction? = nil, isChecking: Bool = false) {
        self.id = id
        self.severity = severity
        self.notice = notice
        self.places = places
        self.action = action
        self.isChecking = isChecking
    }
}

nonisolated enum NotificationDiagnostics {
    /// iOS が同時に監視できる場所の数。
    static let regionLimit = 20

    /// 常に 10 件、順序は `DiagnosticItemID.allCases` のとおり。
    static func evaluate(_ input: DiagnosticInput) -> [DiagnosticItem] {
        let p = input.permissions
        let notices = PermissionNotice.resolveAll(p)
        let notificationReadable = p.notification == .allowed

        // 1. 位置情報の許可
        let locationNotice = notices.first {
            switch $0 {
            case .locationDenied, .locationRestricted, .locationNotDetermined, .locationWhenInUseOnly: return true
            default: return false
            }
        }
        let locationItem: DiagnosticItem
        if let notice = locationNotice {
            let severity: DiagnosticSeverity = notice == .locationWhenInUseOnly ? .warning : .problem
            locationItem = DiagnosticItem(id: .locationAccess, severity: severity, notice: notice,
                                          action: notice.action.map { .permission($0) })
        } else {
            locationItem = DiagnosticItem(id: .locationAccess, severity: .ok)
        }

        // 2. 正確な位置情報（使用中でも、オフなら警告にする）
        let preciseItem: DiagnosticItem
        if !p.location.isAuthorized {
            preciseItem = DiagnosticItem(id: .preciseLocation, severity: .info)
        } else if !p.isPreciseLocation {
            preciseItem = DiagnosticItem(id: .preciseLocation, severity: .warning, notice: .locationReducedAccuracy,
                                         action: .permission(.openSettings))
        } else {
            preciseItem = DiagnosticItem(id: .preciseLocation, severity: .ok)
        }

        // 3. 通知の許可
        let permissionItem: DiagnosticItem
        switch p.notification {
        case .unknown:
            permissionItem = DiagnosticItem(id: .notificationPermission, severity: .ok, isChecking: true)
        case .denied:
            permissionItem = DiagnosticItem(id: .notificationPermission, severity: .problem,
                                            notice: .notificationsDenied, action: .permission(.openSettings))
        case .notDetermined:
            permissionItem = DiagnosticItem(id: .notificationPermission, severity: .problem,
                                            notice: .notificationsNotDetermined, action: .permission(.requestNotifications))
        case .allowed:
            permissionItem = DiagnosticItem(id: .notificationPermission, severity: .ok)
        }

        // 4・5. 通知の出し方・時刻指定要約。許可が無いときは 3 行目が問題として出ているので重ねない
        let presentationItem: DiagnosticItem
        let summaryItem: DiagnosticItem
        if p.notification == .unknown || (notificationReadable && input.presentation == nil) {
            presentationItem = DiagnosticItem(id: .presentation, severity: .ok, isChecking: true)
            summaryItem = DiagnosticItem(id: .scheduledSummary, severity: .ok, isChecking: true)
        } else if !notificationReadable {
            presentationItem = DiagnosticItem(id: .presentation, severity: .info)
            summaryItem = DiagnosticItem(id: .scheduledSummary, severity: .info)
        } else {
            let pres = input.presentation ?? NotificationPresentation(showsAnywhere: true, isInScheduledSummary: false)
            presentationItem = pres.showsAnywhere
                ? DiagnosticItem(id: .presentation, severity: .ok)
                : DiagnosticItem(id: .presentation, severity: .warning, action: .openNotificationSettings)
            summaryItem = pres.isInScheduledSummary
                ? DiagnosticItem(id: .scheduledSummary, severity: .warning, action: .openNotificationSettings)
                : DiagnosticItem(id: .scheduledSummary, severity: .ok)
        }

        // 6. アプリ内の通知スイッチ
        let switchItem = input.inAppNotificationsEnabled
            ? DiagnosticItem(id: .inAppSwitch, severity: .ok)
            : DiagnosticItem(id: .inAppSwitch, severity: .problem, action: .enableInAppNotifications)

        // 7. バックグラウンド更新（制限は利用者が変えられないのでボタンなし）
        let refreshItem: DiagnosticItem
        switch input.backgroundRefresh {
        case .available: refreshItem = DiagnosticItem(id: .backgroundRefresh, severity: .ok)
        case .denied: refreshItem = DiagnosticItem(id: .backgroundRefresh, severity: .warning, action: .permission(.openSettings))
        case .restricted: refreshItem = DiagnosticItem(id: .backgroundRefresh, severity: .warning)
        }

        // 8. 低電力モード
        let lowPowerItem = DiagnosticItem(id: .lowPowerMode, severity: input.isLowPowerMode ? .info : .ok)

        // 9. 集中モード（取得しない。常に説明）
        let focusItem = DiagnosticItem(id: .focus, severity: .info)

        // 10. 監視中の場所
        let placesItem: DiagnosticItem
        let limit = regionLimit
        if !input.isMonitoringAvailable {
            placesItem = DiagnosticItem(id: .monitoredPlaces, severity: .problem, places: .unsupported)
        } else if !p.location.isAuthorized {
            placesItem = DiagnosticItem(id: .monitoredPlaces, severity: .info, places: .notAuthorized)
        } else if input.requiredRegions > limit {
            // 登録し直しても直らないので、ボタンは出さない
            placesItem = DiagnosticItem(
                id: .monitoredPlaces, severity: .problem,
                places: .overLimit(required: input.requiredRegions, unmonitored: input.requiredRegions - limit))
        } else if input.monitoredRegions < min(input.requiredRegions, limit) {
            placesItem = DiagnosticItem(
                id: .monitoredPlaces, severity: .warning,
                places: .underRegistered(monitored: input.monitoredRegions, required: input.requiredRegions),
                action: .reRegisterGeofences)
        } else {
            var nearUsed: Int?
            if case .nearLimit(let used) = MonitoringLimitState.resolve(requiredRegions: input.requiredRegions, limit: limit) {
                nearUsed = used
            }
            placesItem = DiagnosticItem(id: .monitoredPlaces, severity: .ok,
                                        places: .ok(monitored: input.monitoredRegions, nearLimitUsed: nearUsed))
        }

        return [locationItem, preciseItem, permissionItem, presentationItem, summaryItem,
                switchItem, refreshItem, lowPowerItem, focusItem, placesItem]
    }

    /// 「要確認」に数える件数（warning 以上。info は数えない）。
    static func issueCount(_ items: [DiagnosticItem]) -> Int {
        items.filter { $0.severity >= .warning }.count
    }
}

/// テスト通知の結果。
nonisolated enum TestNotificationResult: Equatable {
    case delivered
    case scheduledButNotConfirmed
    case notAuthorized
    case failed
}

// MARK: - 文言の選択

nonisolated enum DiagnosticText {
    static func title(_ id: DiagnosticItemID) -> String {
        switch id {
        case .locationAccess: return String(localized: "Location Access")
        case .preciseLocation: return String(localized: "Precise Location")
        case .notificationPermission: return String(localized: "Notification Permission")
        case .presentation: return String(localized: "How Alerts Appear")
        case .scheduledSummary: return String(localized: "Scheduled Summary")
        case .inAppSwitch: return String(localized: "Notifications in GeoMemo")
        case .backgroundRefresh: return String(localized: "Background App Refresh")
        case .lowPowerMode: return String(localized: "Low Power Mode")
        case .focus: return String(localized: "Focus")
        case .monitoredPlaces: return String(localized: "Places Being Watched")
        }
    }

    /// 状態を示す語（アイコンと一緒に出し、VoiceOver でも読む）。
    static func severityLabel(_ severity: DiagnosticSeverity) -> String {
        switch severity {
        case .ok: return String(localized: "All good")
        case .info: return String(localized: "For reference")
        case .warning: return String(localized: "Caution")
        case .problem: return String(localized: "Problem")
        }
    }

    /// 行の右側に出す現在の値。
    static func value(_ item: DiagnosticItem, input: DiagnosticInput) -> String {
        if item.isChecking { return String(localized: "Checking…") }
        switch item.id {
        case .locationAccess:
            return item.severity == .ok ? String(localized: "Always Allowed") : severityLabel(item.severity)
        case .preciseLocation, .inAppSwitch, .backgroundRefresh:
            return item.severity == .ok ? String(localized: "On") : severityLabel(item.severity)
        case .notificationPermission:
            return item.severity == .ok ? String(localized: "Allowed") : severityLabel(item.severity)
        case .presentation:
            return item.severity == .ok
                ? String(localized: "Shown as banners and on the Lock Screen") : severityLabel(item.severity)
        case .scheduledSummary:
            return item.severity == .ok ? String(localized: "Off") : severityLabel(item.severity)
        case .lowPowerMode:
            return item.severity == .ok ? String(localized: "Off") : String(localized: "On")
        case .focus:
            return String(localized: "Can't be checked")
        case .monitoredPlaces:
            if case .ok(let monitored, _) = item.places { return String(localized: "\(monitored) of 20") }
            return severityLabel(item.severity)
        }
    }

    /// 問題・注意・参考のときに展開して出す見出し（地図のバナーの題）。
    static func headline(_ item: DiagnosticItem) -> String? {
        guard item.severity != .ok || item.id == .focus, let notice = item.notice else { return nil }
        return MapGuidance.permission(notice).title
    }

    /// 展開して出す本文。出さない（問題なしで補足も無い）ときは nil。
    static func message(_ item: DiagnosticItem) -> String? {
        if item.isChecking { return nil }
        if let notice = item.notice, item.severity != .ok {
            return MapGuidance.permission(notice).message
        }
        switch item.id {
        case .locationAccess, .notificationPermission:
            return nil
        case .inAppSwitch:
            return item.severity == .ok ? nil : String(localized: "The Notifications switch in GeoMemo's settings is off, so no alerts are sent.")
        case .preciseLocation:
            return item.severity == .info ? String(localized: "Allow location access first.") : nil
        case .presentation:
            switch item.severity {
            case .warning: return String(localized: "Alerts are hidden everywhere. Turn on Lock Screen, Notification Center, or Banners in Settings.")
            case .info: return String(localized: "Allow notifications first.")
            default: return nil
            }
        case .scheduledSummary:
            switch item.severity {
            case .warning: return String(localized: "GeoMemo is in your Scheduled Summary, so alerts arrive later in a batch, not when you reach a place.")
            case .info: return String(localized: "Allow notifications first.")
            default: return nil
            }
        case .backgroundRefresh:
            return item.severity == .ok ? nil : String(localized: "Background App Refresh is off. Alerts may not arrive while the app is closed.")
        case .lowPowerMode:
            return item.severity == .info ? String(localized: "Low Power Mode is on. Arrival alerts may be late.") : nil
        case .focus:
            return String(localized: "GeoMemo can't see whether a Focus is on. While a Focus is on, alerts go to Notification Center without a banner or sound. To always see them, add GeoMemo to the Focus's allowed apps.")
        case .monitoredPlaces:
            return placesMessage(item.places)
        }
    }

    private static func placesMessage(_ state: MonitoredPlacesState?) -> String? {
        switch state {
        case .unsupported:
            return String(localized: "This device can't watch places.")
        case .notAuthorized:
            return String(localized: "Not watching because location access is off.")
        case .overLimit(let required, let unmonitored):
            return String(localized: "You have \(required) places, but iOS can watch only 20. \(unmonitored) won't send alerts. Complete or delete some memos.")
        case .underRegistered(let monitored, let required):
            return String(localized: "\(monitored) of your \(required) places are being watched. Tap to register them again.")
        case .ok(_, let nearUsed?):
            return MapGuidance.monitoringLimit(.nearLimit(used: nearUsed)).message
        case .ok, nil:
            return nil
        }
    }

    static func actionTitle(_ action: DiagnosticAction) -> String {
        switch action {
        case .permission(let a): return a.title
        case .openNotificationSettings: return String(localized: "Open Notification Settings")
        case .enableInAppNotifications: return String(localized: "Turn On")
        case .reRegisterGeofences: return String(localized: "Register Again")
        }
    }

    /// まとめの文。
    static func summary(issueCount: Int) -> String {
        issueCount == 0
            ? String(localized: "Your alerts are set up to arrive.")
            : String(localized: "\(issueCount) settings may keep alerts from arriving.")
    }

    /// 設定画面の入口の右側。
    static func entryValue(issueCount: Int) -> String {
        issueCount == 0 ? String(localized: "All good") : String(localized: "\(issueCount) to review")
    }

    static func testResultMessage(_ result: TestNotificationResult) -> String {
        switch result {
        case .delivered:
            return String(localized: "The test alert was delivered. If you didn't see a banner or hear a sound, a Focus or your notification settings may be silencing it.")
        case .scheduledButNotConfirmed:
            return String(localized: "The test alert was sent, but it hasn't been confirmed yet. Check Notification Center.")
        case .notAuthorized:
            return String(localized: "Allow notifications first.")
        case .failed:
            return String(localized: "The test alert couldn't be sent.")
        }
    }
}

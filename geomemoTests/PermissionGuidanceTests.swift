import Testing
import Foundation
import CoreLocation
import UserNotifications
@testable import geomemo

// MARK: - 許可の不足 → 案内

private func snap(
    _ location: LocationAccess = .always,
    precise: Bool = true,
    _ notification: NotificationAccess = .allowed
) -> PermissionSnapshot {
    PermissionSnapshot(location: location, isPreciseLocation: precise, notification: notification)
}

@Suite("PermissionNotice")
struct PermissionNoticeTests {
    @Test("すべて足りていれば案内なし")
    func allGood() {
        #expect(PermissionNotice.resolve(snap()) == nil)
    }

    @Test("位置情報の段階ごとの案内")
    func locationStages() {
        #expect(PermissionNotice.resolve(snap(.deniedOrRestricted)) == .locationDenied)
        #expect(PermissionNotice.resolve(snap(.notDetermined)) == .locationNotDetermined)
        #expect(PermissionNotice.resolve(snap(.whenInUse)) == .locationWhenInUseOnly)
    }

    @Test("正確な位置情報がオフなら案内（許可済みのとき）")
    func reducedAccuracy() {
        #expect(PermissionNotice.resolve(snap(.always, precise: false)) == .locationReducedAccuracy)
        // 使用中のみのほうが重要なので、そちらを先に出す
        #expect(PermissionNotice.resolve(snap(.whenInUse, precise: false)) == .locationWhenInUseOnly)
        // 位置情報が拒否なら、正確さの案内は出さない
        #expect(PermissionNotice.resolve(snap(.deniedOrRestricted, precise: false)) == .locationDenied)
    }

    @Test("通知の拒否・未決定")
    func notifications() {
        #expect(PermissionNotice.resolve(snap(.always, .denied)) == .notificationsDenied)
        #expect(PermissionNotice.resolve(snap(.always, .notDetermined)) == .notificationsNotDetermined)
    }

    @Test("位置情報の不足が通知の不足より先")
    func locationBeforeNotification() {
        #expect(PermissionNotice.resolve(snap(.whenInUse, .denied)) == .locationWhenInUseOnly)
        #expect(PermissionNotice.resolve(snap(.deniedOrRestricted, .denied)) == .locationDenied)
    }

    @Test("ボタンの動作: 未決定は許可ダイアログ、それ以外は設定アプリ")
    func actions() {
        #expect(PermissionNotice.locationNotDetermined.action == .requestLocation)
        #expect(PermissionNotice.notificationsNotDetermined.action == .requestNotifications)
        for notice in [PermissionNotice.locationDenied, .locationWhenInUseOnly, .locationReducedAccuracy, .notificationsDenied] {
            #expect(notice.action == .openSettings)
        }
    }

    @Test("システムの状態からの変換")
    func conversions() {
        #expect(LocationAccess(.notDetermined) == .notDetermined)
        #expect(LocationAccess(.denied) == .deniedOrRestricted)
        #expect(LocationAccess(.restricted) == .deniedOrRestricted)
        #expect(LocationAccess(.authorizedWhenInUse) == .whenInUse)
        #expect(LocationAccess(.authorizedAlways) == .always)
        #expect(NotificationAccess(.notDetermined) == .notDetermined)
        #expect(NotificationAccess(.denied) == .denied)
        #expect(NotificationAccess(.authorized) == .allowed)
        #expect(NotificationAccess(.provisional) == .allowed)
    }
}

// MARK: - 監視上限

@Suite("MonitoringLimitState")
struct MonitoringLimitStateTests {
    @Test("上限に余裕があれば ok")
    func ok() {
        #expect(MonitoringLimitState.resolve(requiredRegions: 0) == .ok)
        #expect(MonitoringLimitState.resolve(requiredRegions: 17) == .ok)
    }

    @Test("残り 2 件以下で nearLimit（18〜20 件）")
    func near() {
        #expect(MonitoringLimitState.resolve(requiredRegions: 18) == .nearLimit(used: 18))
        #expect(MonitoringLimitState.resolve(requiredRegions: 20) == .nearLimit(used: 20))
    }

    @Test("21 件以上は overLimit で、監視できない件数を持つ")
    func over() {
        #expect(MonitoringLimitState.resolve(requiredRegions: 21) == .overLimit(used: 21, unmonitored: 1))
        #expect(MonitoringLimitState.resolve(requiredRegions: 25) == .overLimit(used: 25, unmonitored: 5))
    }
}

// MARK: - 地図の案内（優先順位と「閉じたら 1 週間」）

@Suite("MapGuidance")
struct MapGuidanceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("何も不足がなければ nil")
    func none() {
        #expect(MapGuidance.resolve(permissions: snap(), requiredRegions: 3, dismissedKey: nil, dismissedAt: nil, now: now) == nil)
    }

    @Test("許可の不足が監視上限より先")
    func permissionFirst() {
        let g = MapGuidance.resolve(permissions: snap(.whenInUse), requiredRegions: 25, dismissedKey: nil, dismissedAt: nil, now: now)
        #expect(g == .permission(.locationWhenInUseOnly))
    }

    @Test("許可が足りていて上限超過なら上限の案内")
    func limitOnly() {
        let g = MapGuidance.resolve(permissions: snap(), requiredRegions: 22, dismissedKey: nil, dismissedAt: nil, now: now)
        #expect(g == .monitoringLimit(.overLimit(used: 22, unmonitored: 2)))
    }

    @Test("閉じてから 1 週間未満は同じ案内を出さない")
    func suppressedWithinWeek() {
        let key = MapGuidance.permission(.locationWhenInUseOnly).dismissalKey
        let sixDays = now.addingTimeInterval(-6 * 24 * 3600)
        #expect(MapGuidance.resolve(permissions: snap(.whenInUse), requiredRegions: 0, dismissedKey: key, dismissedAt: sixDays, now: now) == nil)
    }

    @Test("1 週間たてば再び出す")
    func shownAfterWeek() {
        let key = MapGuidance.permission(.locationWhenInUseOnly).dismissalKey
        let eightDays = now.addingTimeInterval(-8 * 24 * 3600)
        #expect(MapGuidance.resolve(permissions: snap(.whenInUse), requiredRegions: 0, dismissedKey: key, dismissedAt: eightDays, now: now) == .permission(.locationWhenInUseOnly))
    }

    @Test("別の案内に変われば、閉じた直後でも出す")
    func differentGuidanceNotSuppressed() {
        let key = MapGuidance.permission(.locationWhenInUseOnly).dismissalKey
        let g = MapGuidance.resolve(permissions: snap(.always, .denied), requiredRegions: 0, dismissedKey: key, dismissedAt: now, now: now)
        #expect(g == .permission(.notificationsDenied))
    }

    @Test("許可の案内を閉じていても、上限超過は次の候補として出す")
    func fallsThroughToLimit() {
        let key = MapGuidance.permission(.locationWhenInUseOnly).dismissalKey
        let g = MapGuidance.resolve(permissions: snap(.whenInUse), requiredRegions: 21, dismissedKey: key, dismissedAt: now, now: now)
        #expect(g == .monitoringLimit(.overLimit(used: 21, unmonitored: 1)))
    }

    @Test("時計が戻っている（閉じた時刻が未来）場合は抑止しない")
    func futureDismissal() {
        let key = MapGuidance.permission(.locationDenied).dismissalKey
        let future = now.addingTimeInterval(3600)
        #expect(MapGuidance.resolve(permissions: snap(.deniedOrRestricted), requiredRegions: 0, dismissedKey: key, dismissedAt: future, now: now) == .permission(.locationDenied))
    }
}

// MARK: - オンボーディングの順序

@Suite("OnboardingStep")
struct OnboardingStepTests {
    @Test("使用中が許可されたら「常に」の説明へ")
    func whenInUseGranted() {
        #expect(OnboardingStep.next(after: .whenInUse, location: .whenInUse) == .always)
    }

    @Test("使用中が拒否・既に常に・未決定なら「常に」は飛ばして通知へ")
    func skipAlways() {
        #expect(OnboardingStep.next(after: .whenInUse, location: .deniedOrRestricted) == .notifications)
        #expect(OnboardingStep.next(after: .whenInUse, location: .always) == .notifications)
        #expect(OnboardingStep.next(after: .whenInUse, location: .notDetermined) == .notifications)
    }

    @Test("順序: ようこそ → 使用中 → 常に → 通知 → 完了")
    func order() {
        #expect(OnboardingStep.next(after: .welcome, location: .notDetermined) == .whenInUse)
        #expect(OnboardingStep.next(after: .always, location: .whenInUse) == .notifications)
        #expect(OnboardingStep.next(after: .notifications, location: .always) == nil)
    }
}

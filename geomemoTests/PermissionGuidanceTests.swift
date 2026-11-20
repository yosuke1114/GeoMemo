import Testing
import Foundation
import CoreLocation
import UserNotifications
import CloudKit
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
        #expect(PermissionNotice.resolve(snap(.denied)) == .locationDenied)
        #expect(PermissionNotice.resolve(snap(.notDetermined)) == .locationNotDetermined)
        #expect(PermissionNotice.resolve(snap(.whenInUse)) == .locationWhenInUseOnly)
    }

    @Test("正確な位置情報がオフなら案内（許可済みのとき）")
    func reducedAccuracy() {
        #expect(PermissionNotice.resolve(snap(.always, precise: false)) == .locationReducedAccuracy)
        // 使用中のみのほうが重要なので、そちらを先に出す
        #expect(PermissionNotice.resolve(snap(.whenInUse, precise: false)) == .locationWhenInUseOnly)
        // 位置情報が拒否なら、正確さの案内は出さない
        #expect(PermissionNotice.resolve(snap(.denied, precise: false)) == .locationDenied)
    }

    @Test("通知の拒否・未決定")
    func notifications() {
        #expect(PermissionNotice.resolve(snap(.always, .denied)) == .notificationsDenied)
        #expect(PermissionNotice.resolve(snap(.always, .notDetermined)) == .notificationsNotDetermined)
    }

    @Test("位置情報の不足が通知の不足より先")
    func locationBeforeNotification() {
        #expect(PermissionNotice.resolve(snap(.whenInUse, .denied)) == .locationWhenInUseOnly)
        #expect(PermissionNotice.resolve(snap(.denied, .denied)) == .locationDenied)
    }

    @Test("ボタンの動作: 未決定は許可ダイアログ、使用中のみは「常に」の要求、拒否は設定アプリ、制限はボタンなし")
    func actions() {
        #expect(PermissionNotice.locationNotDetermined.action == .requestLocation)
        #expect(PermissionNotice.notificationsNotDetermined.action == .requestNotifications)
        #expect(PermissionNotice.locationWhenInUseOnly.action == .requestAlways)
        for notice in [PermissionNotice.locationDenied, .locationReducedAccuracy, .notificationsDenied] {
            #expect(notice.action == .openSettings)
        }
        #expect(PermissionNotice.locationRestricted.action == nil)
    }

    @Test("保護者による制限は専用の案内")
    func restricted() {
        #expect(PermissionNotice.resolve(snap(.restricted)) == .locationRestricted)
    }

    @Test("通知の状態を読み込む前は案内しない")
    func notificationUnknown() {
        #expect(PermissionNotice.resolve(snap(.always, .unknown)) == nil)
        #expect(PermissionNotice.resolveAll(snap(.whenInUse, .unknown)) == [.locationWhenInUseOnly])
    }

    @Test("不足は重要な順にすべて並ぶ")
    func resolveAll() {
        #expect(PermissionNotice.resolveAll(snap(.whenInUse, .denied)) == [.locationWhenInUseOnly, .notificationsDenied])
        #expect(PermissionNotice.resolveAll(snap()) == [])
    }

    @Test("システムの状態からの変換")
    func conversions() {
        #expect(LocationAccess(.notDetermined) == .notDetermined)
        #expect(LocationAccess(.denied) == .denied)
        #expect(LocationAccess(.restricted) == .restricted)
        #expect(LocationAccess(.authorizedWhenInUse) == .whenInUse)
        #expect(LocationAccess(.authorizedAlways) == .always)
        #expect(NotificationAccess(nil) == .unknown)
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

@Suite("RegionCount")
struct RegionCountTests {
    @Test("経由地が 2 未満のルートは登録されないので数えない")
    func shortRoute() {
        #expect(MonitoringLimitState.regionCount(isRoute: true, waypointCount: 0) == 0)
        #expect(MonitoringLimitState.regionCount(isRoute: true, waypointCount: 1) == 0)
        #expect(MonitoringLimitState.regionCount(isRoute: true, waypointCount: 2) == 2)
        #expect(MonitoringLimitState.regionCount(isRoute: true, waypointCount: 5) == 5)
        #expect(MonitoringLimitState.regionCount(isRoute: false, waypointCount: 0) == 1)
    }
}

// MARK: - 地図の案内（優先順位と「閉じたら 1 週間」）

@Suite("MapGuidance")
struct MapGuidanceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ days: Double) -> TimeInterval { now.timeIntervalSince1970 - days * 24 * 3600 }
    private func resolve(_ p: PermissionSnapshot, regions: Int = 0, _ d: [String: TimeInterval] = [:]) -> MapGuidance? {
        MapGuidance.resolve(permissions: p, requiredRegions: regions, dismissals: d, now: now)
    }

    @Test("何も不足がなければ nil")
    func none() {
        #expect(resolve(snap(), regions: 3) == nil)
    }

    @Test("許可の不足が監視上限より先")
    func permissionFirst() {
        #expect(resolve(snap(.whenInUse), regions: 25) == .permission(.locationWhenInUseOnly))
    }

    @Test("許可が足りていて上限超過なら上限の案内")
    func limitOnly() {
        #expect(resolve(snap(), regions: 22) == .monitoringLimit(.overLimit(used: 22, unmonitored: 2)))
    }

    @Test("閉じてから 1 週間未満は同じ案内を出さない")
    func suppressedWithinWeek() {
        let key = MapGuidance.permission(.locationWhenInUseOnly).dismissalKey
        #expect(resolve(snap(.whenInUse), [key: ago(6)]) == nil)
    }

    @Test("1 週間たてば再び出す")
    func shownAfterWeek() {
        let key = MapGuidance.permission(.locationWhenInUseOnly).dismissalKey
        #expect(resolve(snap(.whenInUse), [key: ago(8)]) == .permission(.locationWhenInUseOnly))
    }

    @Test("別の案内に変われば、閉じた直後でも出す")
    func differentGuidanceNotSuppressed() {
        let key = MapGuidance.permission(.locationWhenInUseOnly).dismissalKey
        #expect(resolve(snap(.always, .denied), [key: ago(0)]) == .permission(.notificationsDenied))
    }

    @Test("許可の案内を閉じていても、上限超過は次の候補として出す")
    func fallsThroughToLimit() {
        let key = MapGuidance.permission(.locationWhenInUseOnly).dismissalKey
        #expect(resolve(snap(.whenInUse), regions: 21, [key: ago(0)]) == .monitoringLimit(.overLimit(used: 21, unmonitored: 1)))
    }

    @Test("位置の案内を閉じても、通知オフの案内を出す")
    func fallsThroughToNotification() {
        let key = MapGuidance.permission(.locationWhenInUseOnly).dismissalKey
        #expect(resolve(snap(.whenInUse, .denied), [key: ago(0)]) == .permission(.notificationsDenied))
    }

    @Test("時計が戻っている（閉じた時刻が未来）場合は抑止しない")
    func futureDismissal() {
        let key = MapGuidance.permission(.locationDenied).dismissalKey
        #expect(resolve(snap(.denied), [key: now.timeIntervalSince1970 + 3600]) == .permission(.locationDenied))
    }

    @Test("A を閉じ、B を閉じたあとも、A は 1 週間出ない（交互に出続けない）")
    func twoDismissalsKeepBoth() {
        let a = MapGuidance.permission(.locationWhenInUseOnly)
        let b = MapGuidance.permission(.notificationsDenied)
        let p = snap(.whenInUse, .denied)
        var d: [String: TimeInterval] = [:]
        #expect(resolve(p, d) == a)
        d = MapGuidance.recordingDismissal(of: a, in: d, now: now)
        #expect(resolve(p, d) == b)
        d = MapGuidance.recordingDismissal(of: b, in: d, now: now.addingTimeInterval(60))
        #expect(MapGuidance.resolve(permissions: p, requiredRegions: 0, dismissals: d, now: now.addingTimeInterval(3600)) == nil)
        // 6 日後もまだ出ない。8 日後に A から戻る
        #expect(MapGuidance.resolve(permissions: p, requiredRegions: 0, dismissals: d, now: now.addingTimeInterval(6 * 24 * 3600)) == nil)
        #expect(MapGuidance.resolve(permissions: p, requiredRegions: 0, dismissals: d, now: now.addingTimeInterval(8 * 24 * 3600)) == a)
    }

    @Test("閉じた記録は期間を過ぎたものを捨て、JSON で往復できる")
    func pruneAndCodable() {
        let a = MapGuidance.permission(.locationDenied)
        let b = MapGuidance.permission(.notificationsDenied)
        let old = [a.dismissalKey: ago(10)]
        let d = MapGuidance.recordingDismissal(of: b, in: old, now: now)
        #expect(d.keys.sorted() == [b.dismissalKey])
        let round = MapGuidance.decodeDismissals(MapGuidance.encodeDismissals(d))
        #expect(round == d)
        #expect(MapGuidance.decodeDismissals("") == [:])
        #expect(MapGuidance.decodeDismissals("not json") == [:])
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
        #expect(OnboardingStep.next(after: .whenInUse, location: .denied) == .notifications)
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

// MARK: - 受諾した共有の保留キュー

@Suite("PendingShareQueue")
@MainActor
struct PendingShareQueueTests {
    @Test("積んだ順に 1 度だけ取り出せる")
    func enqueueDrain() {
        let q = PendingShareQueue()
        let id = CKRecord.ID(recordName: "r")
        q.enqueue(AcceptedShareInfo(ownerRecordID: "a", ownerName: "A", shareRecordID: id))
        q.enqueue(AcceptedShareInfo(ownerRecordID: "b", ownerName: "B", shareRecordID: id))
        #expect(q.drain().map(\.ownerRecordID) == ["a", "b"])
        #expect(q.drain().isEmpty)
    }
}

import Testing
import Foundation
@testable import geomemo

// 「通知のチェック」の判定ロジックのテスト。画面・システム API には依存しない。

private func input(
    location: LocationAccess = .always,
    precise: Bool = true,
    notification: NotificationAccess = .allowed,
    presentation: NotificationPresentation? = NotificationPresentation(alert: true, lockScreen: true, notificationCenter: true, isInScheduledSummary: false),
    inApp: Bool = true,
    refresh: BackgroundRefreshAccess = .available,
    lowPower: Bool = false,
    required: Int = 3,
    monitored: Int = 3,
    received: Int = 0,
    circle: Bool = false,
    available: Bool = true
) -> DiagnosticInput {
    DiagnosticInput(
        permissions: PermissionSnapshot(location: location, isPreciseLocation: precise, notification: notification),
        presentation: presentation,
        inAppNotificationsEnabled: inApp,
        backgroundRefresh: refresh,
        isLowPowerMode: lowPower,
        requiredRegions: required,
        monitoredRegions: monitored,
        receivedRegions: received,
        hasRotationCircle: circle,
        isMonitoringAvailable: available)
}

private func item(_ id: DiagnosticItemID, _ i: DiagnosticInput) -> DiagnosticItem {
    NotificationDiagnostics.evaluate(i).first { $0.id == id }!
}

@Suite("NotificationDiagnostics")
struct NotificationDiagnosticsTests {

    @Test("すべて足りていれば、問題・注意は 0 件で、10 件が決まった順に並ぶ")
    func allGood() {
        let items = NotificationDiagnostics.evaluate(input())
        #expect(items.map(\.id) == DiagnosticItemID.allCases)
        #expect(items.count == 10)
        #expect(NotificationDiagnostics.issueCount(items) == 0)
        #expect(items.allSatisfy { $0.severity == .ok || $0.severity == .info })
    }

    @Test("どの状態でも 10 件・同じ順序")
    func alwaysTenInOrder() {
        let worst = input(location: .denied, precise: false, notification: .denied, presentation: nil,
                          inApp: false, refresh: .denied, lowPower: true, required: 30, monitored: 0, available: false)
        for i in [input(), worst, input(location: .notDetermined, notification: .unknown, presentation: nil)] {
            #expect(NotificationDiagnostics.evaluate(i).map(\.id) == DiagnosticItemID.allCases)
        }
    }

    @Test("位置情報の許可: 段階ごとの重みとボタン", arguments: [
        (LocationAccess.denied, DiagnosticSeverity.problem, DiagnosticAction.permission(.openSettings) as DiagnosticAction?),
        (.restricted, .problem, nil),
        (.notDetermined, .problem, .permission(.requestLocation)),
        (.whenInUse, .warning, .permission(.requestAlways)),
        (.always, .ok, nil),
    ])
    func locationAccess(access: LocationAccess, severity: DiagnosticSeverity, action: DiagnosticAction?) {
        let it = item(.locationAccess, input(location: access))
        #expect(it.severity == severity)
        #expect(it.action == action)
    }

    @Test("位置情報の許可の文言は、地図のバナーと同じ")
    func locationTextMatchesBanner() {
        let it = item(.locationAccess, input(location: .denied))
        #expect(it.notice == .locationDenied)
        #expect(DiagnosticText.message(it) == MapGuidance.permission(.locationDenied).message)
        #expect(DiagnosticText.headline(it) == MapGuidance.permission(.locationDenied).title)
        #expect(DiagnosticText.actionTitle(.permission(.openSettings)) == MapGuidance.permission(.locationDenied).actionTitle)
    }

    @Test("正確な位置情報: 許可がなければ参考、使用中でもオフなら注意、常にでオフも注意")
    func preciseLocation() {
        #expect(item(.preciseLocation, input(location: .denied, precise: false)).severity == .info)
        #expect(item(.preciseLocation, input(location: .notDetermined, precise: false)).severity == .info)
        #expect(item(.preciseLocation, input(location: .whenInUse, precise: false)).severity == .warning)
        let always = item(.preciseLocation, input(location: .always, precise: false))
        #expect(always.severity == .warning)
        #expect(always.notice == .locationReducedAccuracy)
        #expect(always.action == .permission(.openSettings))
        #expect(item(.preciseLocation, input(location: .always, precise: true)).severity == .ok)
    }

    @Test("通知の許可: 4 段階")
    func notificationPermission() {
        let unknown = item(.notificationPermission, input(notification: .unknown, presentation: nil))
        #expect(unknown.severity == .ok)
        #expect(unknown.isChecking)
        let notDetermined = item(.notificationPermission, input(notification: .notDetermined))
        #expect(notDetermined.severity == .problem)
        #expect(notDetermined.action == .permission(.requestNotifications))
        let denied = item(.notificationPermission, input(notification: .denied))
        #expect(denied.severity == .problem)
        #expect(denied.action == .permission(.openSettings))
        #expect(item(.notificationPermission, input(notification: .allowed)).severity == .ok)
    }

    @Test("通知の出し方・時刻指定要約: 許可が無いときは重ねて出さない（参考）")
    func presentationNotStacked() {
        for n in [NotificationAccess.denied, .notDetermined] {
            let i = input(notification: n, presentation: NotificationPresentation(alert: false, lockScreen: false, notificationCenter: false, isInScheduledSummary: true))
            #expect(item(.presentation, i).severity == .info)
            #expect(item(.scheduledSummary, i).severity == .info)
        }
    }

    @Test("通知の出し方・時刻指定要約: 読み込み前は確認中（問題に数えない）")
    func presentationChecking() {
        for i in [input(notification: .unknown, presentation: nil), input(notification: .allowed, presentation: nil)] {
            #expect(item(.presentation, i).isChecking)
            #expect(item(.scheduledSummary, i).isChecking)
            #expect(NotificationDiagnostics.issueCount(NotificationDiagnostics.evaluate(i)) == 0)
        }
    }

    @Test("通知の出し方: すべてオフなら注意、時刻指定要約に入っていれば注意")
    func presentationAndSummary() {
        let hidden = input(presentation: NotificationPresentation(alert: false, lockScreen: false, notificationCenter: false, isInScheduledSummary: false))
        #expect(item(.presentation, hidden).severity == .warning)
        #expect(item(.presentation, hidden).action == .openNotificationSettings)
        #expect(item(.scheduledSummary, hidden).severity == .ok)
        let summary = input(presentation: NotificationPresentation(alert: true, lockScreen: true, notificationCenter: true, isInScheduledSummary: true))
        #expect(item(.scheduledSummary, summary).severity == .warning)
        #expect(item(.presentation, summary).severity == .ok)
    }

    @Test("通知の出し方: バナーとロック画面が両方オフなら、通知センターだけオンでも注意。どちらかオンなら問題なし")
    func presentationSurfaces() {
        func pres(_ a: Bool, _ l: Bool, _ n: Bool) -> DiagnosticInput {
            input(presentation: NotificationPresentation(alert: a, lockScreen: l, notificationCenter: n, isInScheduledSummary: false))
        }
        #expect(item(.presentation, pres(false, false, true)).severity == .warning)
        #expect(item(.presentation, pres(true, false, false)).severity == .ok)
        #expect(item(.presentation, pres(false, true, false)).severity == .ok)
        // 値の文言は、実際にオンのものから組み立てる
        let both = DiagnosticText.presentationSummary(NotificationPresentation(alert: true, lockScreen: false, notificationCenter: true, isInScheduledSummary: false))
        let all = DiagnosticText.presentationSummary(NotificationPresentation(alert: true, lockScreen: true, notificationCenter: true, isInScheduledSummary: false))
        #expect(both != all)
    }

    @Test("低電力モード中は、バックグラウンド更新の行を参考にとどめ、ボタンを出さない")
    func backgroundRefreshInLowPower() {
        let denied = item(.backgroundRefresh, input(refresh: .denied, lowPower: true))
        #expect(denied.severity == .info)
        #expect(denied.action == nil)
        #expect(item(.backgroundRefresh, input(refresh: .restricted, lowPower: true)).severity == .info)
        #expect(item(.backgroundRefresh, input(refresh: .available, lowPower: true)).severity == .ok)
    }

    @Test("受信した依頼だけで上限超過でも、監視に入っていなければ「登録し直す」を出す")
    func overLimitWithUnmonitoredReceived() {
        var i = input(required: 22, monitored: 20, received: 22)
        i.receivedUnmonitored = 1
        #expect(item(.monitoredPlaces, i).action == .reRegisterGeofences)
        i.receivedUnmonitored = 0
        #expect(item(.monitoredPlaces, i).action == nil)
    }

    @Test("テスト通知の結果: 表示の通知を受けていれば届いた。送信より前の通知は数えない")
    func testNotificationDecision() {
        let sent = Date(timeIntervalSince1970: 1_000)
        let before = sent.addingTimeInterval(-60), after = sent.addingTimeInterval(6)
        #expect(TestNotificationResult.decide(presentedAt: after, deliveredDates: [], sentAt: sent) == .delivered)
        #expect(TestNotificationResult.decide(presentedAt: nil, deliveredDates: [after], sentAt: sent) == .delivered)
        // 前回の分が通知センターに残っているだけ
        #expect(TestNotificationResult.decide(presentedAt: nil, deliveredDates: [before], sentAt: sent) == .scheduledButNotConfirmed)
        #expect(TestNotificationResult.decide(presentedAt: before, deliveredDates: [], sentAt: sent) == .scheduledButNotConfirmed)
        #expect(TestNotificationResult.decide(presentedAt: nil, deliveredDates: [], sentAt: sent) == .scheduledButNotConfirmed)
    }

    @Test("アプリ内の通知スイッチ: オフは問題、ボタンはオンにする")
    func inAppSwitch() {
        let off = item(.inAppSwitch, input(inApp: false))
        #expect(off.severity == .problem)
        #expect(off.action == .enableInAppNotifications)
        #expect(item(.inAppSwitch, input(inApp: true)).severity == .ok)
    }

    @Test("バックグラウンド更新: 3 状態")
    func backgroundRefresh() {
        #expect(item(.backgroundRefresh, input(refresh: .available)).severity == .ok)
        let denied = item(.backgroundRefresh, input(refresh: .denied))
        #expect(denied.severity == .warning)
        #expect(denied.action == .permission(.openSettings))
        let restricted = item(.backgroundRefresh, input(refresh: .restricted))
        #expect(restricted.severity == .warning)
        #expect(restricted.action == nil)
    }

    @Test("低電力モード・集中モードは参考で、要確認に数えない")
    func infoOnly() {
        let i = input(lowPower: true)
        #expect(item(.lowPowerMode, i).severity == .info)
        #expect(item(.lowPowerMode, input(lowPower: false)).severity == .ok)
        #expect(item(.focus, i).severity == .info)
        #expect(item(.focus, i).action == nil)
        #expect(NotificationDiagnostics.issueCount(NotificationDiagnostics.evaluate(i)) == 0)
    }

    @Test("監視中の場所: 未許可・対応外")
    func monitoredNotAvailable() {
        #expect(item(.monitoredPlaces, input(location: .denied, required: 5, monitored: 0)).places == .notAuthorized)
        #expect(item(.monitoredPlaces, input(location: .notDetermined)).severity == .info)
        let unsupported = item(.monitoredPlaces, input(available: false))
        #expect(unsupported.places == .unsupported)
        #expect(unsupported.severity == .problem)
    }

    @Test("監視中の場所: 0 件・19 件・20 件・21 件")
    func monitoredCounts() {
        let zero = item(.monitoredPlaces, input(required: 0, monitored: 0))
        #expect(zero.places == .ok(monitored: 0, nearLimitUsed: nil))
        #expect(zero.severity == .ok)
        let nineteen = item(.monitoredPlaces, input(required: 19, monitored: 19, received: 19))
        #expect(nineteen.severity == .ok)
        #expect(nineteen.places == .ok(monitored: 19, nearLimitUsed: 19))
        let twenty = item(.monitoredPlaces, input(required: 20, monitored: 20, received: 20))
        #expect(twenty.severity == .ok)
        #expect(twenty.places == .ok(monitored: 20, nearLimitUsed: 20))
        // 自分のメモが 21 件以上: 19 件＋入れ替え用の円。問題にしない
        let over = item(.monitoredPlaces, input(required: 21, monitored: 20, circle: true))
        #expect(over.severity == .ok)
        #expect(over.places == .rotating(monitored: 19, total: 21))
        #expect(over.action == nil)
        // 受信した依頼だけで 21 件以上は、入れ替えられず溢れる
        let overReceived = item(.monitoredPlaces, input(required: 21, monitored: 20, received: 21))
        #expect(overReceived.severity == .problem)
        #expect(overReceived.places == .overLimit(required: 21, unmonitored: 1))
        #expect(overReceived.action == nil)   // 登録し直しても直らない
    }

    @Test("監視中の場所: 入れ替え中に登録が足りなければ注意（現在地が分からず円が無い間も 19 件は登録済み）")
    func rotatingUnderRegistered() {
        let noCircle = item(.monitoredPlaces, input(required: 30, monitored: 19))
        #expect(noCircle.places == .rotating(monitored: 19, total: 30))
        let under = item(.monitoredPlaces, input(required: 30, monitored: 11, circle: true))
        #expect(under.severity == .warning)
        #expect(under.action == .reRegisterGeofences)
    }

    @Test("監視中の場所: 登録が足りなければ注意で「登録し直す」。多い分には問題にしない")
    func monitoredUnderAndOver() {
        let under = item(.monitoredPlaces, input(required: 5, monitored: 3))
        #expect(under.severity == .warning)
        #expect(under.places == .underRegistered(monitored: 3, required: 5))
        #expect(under.action == .reRegisterGeofences)
        // 上限を超えているときの足りなさは、上限（20）までの登録で足りる
        #expect(item(.monitoredPlaces, input(required: 25, monitored: 20, circle: true)).places == .rotating(monitored: 19, total: 25))
        // 消したメモの領域が残っているなど、登録のほうが多い
        let extra = item(.monitoredPlaces, input(required: 2, monitored: 4))
        #expect(extra.severity == .ok)
        #expect(extra.places == .ok(monitored: 4, nearLimitUsed: nil))
    }

    @Test("要確認の件数は warning 以上だけ")
    func issueCount() {
        let i = input(location: .whenInUse, notification: .denied, presentation: nil, inApp: false, lowPower: true)
        // 位置情報（注意）・通知の許可（問題）・アプリ内スイッチ（問題）。通知の出し方・要約は重ねず、低電力は参考
        #expect(NotificationDiagnostics.issueCount(NotificationDiagnostics.evaluate(i)) == 3)
    }

    @Test("すべての項目に題があり、問題・注意の項目には本文がある")
    func textExists() {
        let worst = input(location: .whenInUse, precise: false, notification: .denied, presentation: nil,
                          inApp: false, refresh: .denied, lowPower: true, required: 30, monitored: 0)
        for it in NotificationDiagnostics.evaluate(worst) {
            #expect(!DiagnosticText.title(it.id).isEmpty)
            if it.severity >= .warning { #expect(DiagnosticText.message(it) != nil) }
        }
    }

    @Test("まとめの文は件数で切り替わる")
    func summary() {
        #expect(DiagnosticText.summary(issueCount: 0) != DiagnosticText.summary(issueCount: 2))
        #expect(DiagnosticText.entryValue(issueCount: 0) != DiagnosticText.entryValue(issueCount: 2))
    }
}

@Suite("DiagnosticsLog")
struct DiagnosticsLogTests {

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "geomemo.tests.diagnostics.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("記録前は nil、記録後に読める。2 つは別々")
    func recordAndRead() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let log = DiagnosticsLog(defaults: defaults)
        #expect(log.lastRegionEventAt == nil)
        #expect(log.lastNotificationAt == nil)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        log.recordRegionEvent(at: t)
        #expect(log.lastRegionEventAt == t)
        #expect(log.lastNotificationAt == nil)
        log.recordNotification(at: t.addingTimeInterval(60))
        #expect(log.lastNotificationAt == t.addingTimeInterval(60))
    }

    @Test("テスト通知の受信記録は、リセットで消え、記録で読める")
    func probe() {
        let probe = TestNotificationProbe()
        #expect(probe.presentedAt == nil)
        let t = Date(timeIntervalSince1970: 5)
        probe.markPresented(at: t)
        #expect(probe.presentedAt == t)
        probe.reset()
        #expect(probe.presentedAt == nil)
    }

    @Test("書くのは時刻の 2 つのキーだけ")
    func writesOnlyTwoKeys() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let log = DiagnosticsLog(defaults: defaults)
        log.recordRegionEvent()
        log.recordNotification()
        let keys = Set(defaults.persistentDomain(forName: name)?.keys.map { $0 } ?? [])
        #expect(keys == [DiagnosticsLog.regionEventKey, DiagnosticsLog.notificationKey])
        #expect(defaults.object(forKey: DiagnosticsLog.regionEventKey) is Double)
    }
}

@Suite("GeofenceRegistrar.requiredRegionCount")
struct RequiredRegionCountTests {

    private func memo(isRoute: Bool = false, waypoints: Int = 0, done: Bool = false) -> GeoMemo {
        let m = GeoMemo(title: "m", note: "", latitude: 35, longitude: 139, radius: 100, isRouteTrigger: isRoute,
                        waypointData: try? JSONEncoder().encode(
                            (0..<waypoints).map { RouteWaypoint(latitude: 35 + Double($0) * 0.01, longitude: 139) }))
        m.isDone = done
        return m
    }

    private func shared(mine: Bool = false, status: ShareStatus = .active) -> SharedMemo {
        SharedMemo(ckRecordName: UUID().uuidString, memoTitle: "s", memoLocationName: "", memoLatitude: 35,
                   memoLongitude: 139, memoRadius: 100, memoDeadline: nil, memoTimeWindowStart: nil,
                   memoTimeWindowEnd: nil, requesterRecordID: "", requesterName: "", recipientRecordID: "",
                   recipientName: "", autoComplete: false, isMyRequest: mine, status: status,
                   firedAt: nil, completedAt: nil)
    }

    @MainActor
    @Test("完了済みは数えない。ルートは経由地の数（2 未満は 0）。受信した依頼は active だけ")
    func counts() {
        let memos = [memo(), memo(done: true), memo(isRoute: true, waypoints: 3), memo(isRoute: true, waypoints: 1)]
        let sharedMemos = [shared(), shared(status: .fired), shared(status: .cancelled), shared(mine: true)]
        #expect(GeofenceRegistrar.requiredRegionCount(memos: memos, sharedMemos: sharedMemos) == 1 + 3 + 1)
    }
}

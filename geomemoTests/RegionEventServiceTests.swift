import Testing
import Foundation
import SwiftData
import CloudKit
import CoreLocation
import UIKit
@testable import geomemo

// MARK: - 純粋ロジック

@Suite("RegionEventPlanner")
struct RegionEventPlannerTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }
    /// 2026-11-17（火）12:00 JST
    private var noon: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12))! }

    private func state(
        notifyOnEntry: Bool = true, notifyOnExit: Bool = true, isDone: Bool = false,
        deadline: Date? = nil, start: Int? = nil, end: Int? = nil, days: [Int]? = nil,
        dwell: Int? = nil, exitDelay: Int? = nil
    ) -> MemoTriggerState {
        MemoTriggerState(title: "t", note: "n", notifyOnEntry: notifyOnEntry, notifyOnExit: notifyOnExit,
                         isDone: isDone, deadline: deadline, timeWindowStart: start, timeWindowEnd: end,
                         activeDays: days, dwellMinutes: dwell, exitDelayMinutes: exitDelay)
    }

    @Test("入った: 条件なし → 即通知。滞在あり → 滞在後")
    func entry() {
        #expect(RegionEventPlanner.entry(state(), now: noon, calendar: calendar) == .immediate)
        #expect(RegionEventPlanner.entry(state(dwell: 10), now: noon, calendar: calendar) == .dwell(minutes: 10))
    }

    @Test("入った: 完了済み・入ったとき通知オフ・期限切れ・時間帯外・曜日外は通知しない")
    func entrySuppressed() {
        #expect(RegionEventPlanner.entry(state(isDone: true), now: noon, calendar: calendar) == .none)
        #expect(RegionEventPlanner.entry(state(notifyOnEntry: false), now: noon, calendar: calendar) == .none)
        #expect(RegionEventPlanner.entry(state(deadline: noon.addingTimeInterval(-1)), now: noon, calendar: calendar) == .none)
        #expect(RegionEventPlanner.entry(state(start: 13 * 60, end: 18 * 60), now: noon, calendar: calendar) == .none)
        #expect(RegionEventPlanner.entry(state(days: [0, 6]), now: noon, calendar: calendar) == .none)   // 火曜は含まない
        #expect(RegionEventPlanner.entry(state(start: 11 * 60, end: 13 * 60, days: [2]), now: noon, calendar: calendar) == .immediate)
    }

    @Test("出た: 遅延を引き継ぐ。完了済み・出たとき通知オフは通知しない")
    func exit() {
        #expect(RegionEventPlanner.exit(state(), now: noon, calendar: calendar) == .notify(delayMinutes: nil))
        #expect(RegionEventPlanner.exit(state(exitDelay: 5), now: noon, calendar: calendar) == .notify(delayMinutes: 5))
        #expect(RegionEventPlanner.exit(state(isDone: true), now: noon, calendar: calendar) == .none)
        #expect(RegionEventPlanner.exit(state(notifyOnExit: false), now: noon, calendar: calendar) == .none)
    }

    @Test("受信した依頼: 監視中だけ発火。それ以外は監視を止めるだけ")
    func sharedFire() {
        #expect(RegionEventPlanner.sharedFire(isActive: true, autoComplete: false) == .fire(completes: false))
        #expect(RegionEventPlanner.sharedFire(isActive: true, autoComplete: true) == .fire(completes: true))
        #expect(RegionEventPlanner.sharedFire(isActive: false, autoComplete: true) == .stopOnly)
    }

    @Test("どのスレッドからでも呼べる")
    func offMain() async {
        let s = state()
        let c = calendar, n = noon
        let r = await Task.detached { RegionEventPlanner.entry(s, now: n, calendar: c) }.value
        #expect(r == .immediate)
    }
}

// MARK: - サービス（画面なしで動く）

@MainActor
private final class FakeEffects: RegionEventEffects {
    var immediate: [String] = []
    var dwell: [(String, Int)] = []
    var exit: [(String, Int?)] = []
    var cancelledDwell: [String] = []
    var sharedFired: [String] = []
    var statusUpdates: [ShareStatus] = []
    var pending: [PendingShareEvent] = []
    var stopped: [String] = []
    var stoppedRoutes: [String] = []
    var failUpdate = false
    var dequeued: [PendingShareEvent] = []
    var drainCount = 0
    var widgetReloads = 0
    var locationRefreshes = 0
    var reconciles: [(memos: Int, shared: Int)] = []
    /// 書き込みの時点でキューに積まれていたか（保存と同時に積むことの確認）
    var pendingAtWrite = 0

    func scheduleImmediate(title: String, body: String, memoID: String) async { immediate.append(memoID) }
    func scheduleDwell(title: String, body: String, memoID: String, minutes: Int) async { dwell.append((memoID, minutes)) }
    func scheduleExit(title: String, body: String, memoID: String, delayMinutes: Int?) async { exit.append((memoID, delayMinutes)) }
    func cancelDwell(memoID: String) { cancelledDwell.append(memoID) }
    func scheduleSharedFired(memoTitle: String, requesterName: String, sharedID: String) async { sharedFired.append(sharedID) }
    func updateSharedStatus(recordID: CKRecord.ID, status: ShareStatus, date: Date) async throws {
        pendingAtWrite = pending.count
        if failUpdate { throw CKError(.networkUnavailable) }
        statusUpdates.append(status)
    }
    func enqueuePending(_ event: PendingShareEvent) { pending.append(event) }
    func stopMonitoring(identifier: String) { stopped.append(identifier) }
    func stopMonitoringRoute(memoID: String) { stoppedRoutes.append(memoID) }
    func dequeuePending(_ event: PendingShareEvent) {
        dequeued.append(event)
        pending.removeAll { Self.same($0, event) }
    }
    func drainPending() async { drainCount += 1 }
    func reloadWidgets() { widgetReloads += 1 }
    func refreshLocationForRotation() async { locationRefreshes += 1 }
    func reconcileGeofences(memos: [GeoMemo], sharedMemos: [SharedMemo]) {
        reconciles.append((memos.count, sharedMemos.count))
    }

    private static func same(_ a: PendingShareEvent, _ b: PendingShareEvent) -> Bool {
        switch (a, b) {
        case (.fired(let n1, _, _), .fired(let n2, _, _)): return n1 == n2
        case (.completed(let n1, _, _), .completed(let n2, _, _)): return n1 == n2
        default: return false
        }
    }
}

@MainActor
private final class FakeBackgroundTasks: BackgroundTaskControlling {
    var begun: [String] = []
    var ended: [UIBackgroundTaskIdentifier] = []
    var expiration: (@MainActor () -> Void)?
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        begun.append(name)
        self.expiration = expiration
        return UIBackgroundTaskIdentifier(rawValue: 42)
    }
    func end(_ id: UIBackgroundTaskIdentifier) { ended.append(id) }
}

@MainActor
private final class FakeHandler: RegionEventHandling {
    var entered: [String] = []
    var exited: [String] = []
    var shared: [String] = []
    func handleEntered(memoID: String) { entered.append(memoID) }
    func handleExited(memoID: String) { exited.append(memoID) }
    func handleSharedEntered(identifier: String) { shared.append(identifier) }
}

@MainActor
@Suite("RegionEventService", .serialized)
struct RegionEventServiceTests {
    private func makeService() throws -> (RegionEventService, FakeEffects, ModelContext) {
        let schema = GeoMemoStore.makeSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let effects = FakeEffects()
        let service = RegionEventService(effects: effects, container: container)
        return (service, effects, container.mainContext)
    }

    private func memo(_ context: ModelContext, configure: (GeoMemo) -> Void = { _ in }) -> GeoMemo {
        let m = GeoMemo(title: "牛乳", note: "2 本", latitude: 35.68, longitude: 139.76, radius: 100)
        configure(m)
        context.insert(m)
        try? context.save()
        return m
    }

    private func shared(_ context: ModelContext, status: ShareStatus = .active, autoComplete: Bool = false) -> SharedMemo {
        let s = SharedMemo(
            ckRecordName: "rec-\(UUID().uuidString)", memoTitle: "買い物", memoLocationName: "駅",
            memoLatitude: 35.68, memoLongitude: 139.76, memoRadius: 100,
            requesterRecordID: "r1", requesterName: "母", recipientRecordID: "r2", recipientName: "私",
            autoComplete: autoComplete, isMyRequest: false, status: status)
        context.insert(s)
        try? context.save()
        return s
    }

    @Test("入れ替え: 現在地を取ってから、メモと依頼を読み直して入れ替える（画面なし）")
    func rotate() async throws {
        let (service, fx, ctx) = try makeService()
        _ = memo(ctx); _ = memo(ctx); _ = shared(ctx)
        await service.rotate()
        #expect(fx.locationRefreshes == 1)
        #expect(fx.reconciles.count == 1 && fx.reconciles[0].memos == 2 && fx.reconciles[0].shared == 1)
    }

    @Test("入れ替え: バックグラウンドの実行時間を確保し、終わったら返す。進行中の重複は走らせない")
    func rotationTrigger() async throws {
        let (service, fx, ctx) = try makeService()
        _ = memo(ctx)
        let bg = FakeBackgroundTasks()
        service.backgroundTasks = bg
        service.handleRotationTrigger()
        service.handleRotationTrigger()   // 進行中なので無視
        #expect(bg.begun == ["geomemo-region-event"])
        try await Task.sleep(for: .milliseconds(300))
        #expect(fx.reconciles.count == 1)
        #expect(bg.ended.count == 1)
        #expect(!service.isRotating)
    }

    @Test("入った: 即通知が出る（画面なし）")
    func entered() async throws {
        let (service, fx, ctx) = try makeService()
        let m = memo(ctx)
        await service.memoEntered(id: m.id.uuidString)
        #expect(fx.immediate == [m.id.uuidString])
    }

    @Test("入った: 滞在あり → 滞在通知。完了済み・存在しない ID・不正な ID は何もしない")
    func enteredVariants() async throws {
        let (service, fx, ctx) = try makeService()
        let dwell = memo(ctx) { $0.dwellMinutes = 15 }
        let done = memo(ctx) { $0.isDone = true }
        await service.memoEntered(id: dwell.id.uuidString)
        await service.memoEntered(id: done.id.uuidString)
        await service.memoEntered(id: UUID().uuidString)
        await service.memoEntered(id: "not-a-uuid")
        #expect(fx.dwell.count == 1 && fx.dwell[0].1 == 15)
        #expect(fx.immediate.isEmpty)
    }

    @Test("出た: 滞在通知を必ず取り消し、遅延つきで通知する")
    func exited() async throws {
        let (service, fx, ctx) = try makeService()
        let m = memo(ctx) { $0.exitDelayMinutes = 3 }
        await service.memoExited(id: m.id.uuidString)
        #expect(fx.cancelledDwell == [m.id.uuidString])
        #expect(fx.exit.count == 1 && fx.exit[0].1 == 3)
    }

    @Test("出た: 出たとき通知オフでも滞在通知は取り消す")
    func exitedCancelsDwellEvenWhenSilent() async throws {
        let (service, fx, ctx) = try makeService()
        let m = memo(ctx) { $0.notifyOnExit = false }
        await service.memoExited(id: m.id.uuidString)
        #expect(fx.cancelledDwell == [m.id.uuidString])
        #expect(fx.exit.isEmpty)
    }

    @Test("受信した依頼の到着: 状態を fired にして CloudKit へ書き、通知し、監視を止める")
    func sharedFired() async throws {
        let (service, fx, ctx) = try makeService()
        let s = shared(ctx)
        await service.sharedEntered(identifier: s.geofenceIdentifier)
        #expect(s.status == .fired && s.firedAt != nil)
        #expect(fx.statusUpdates == [.fired])
        #expect(fx.sharedFired == [s.id.uuidString])
        #expect(fx.stopped == [s.geofenceIdentifier])
        // 保存と同時に積み（書き込みの時点で 1 件）、成功したら外す
        #expect(fx.pendingAtWrite == 1)
        #expect(fx.pending.isEmpty && fx.dequeued.count == 1)
    }

    @Test("受信した依頼: 自動完了なら completed を一度だけ書く")
    func sharedAutoComplete() async throws {
        let (service, fx, ctx) = try makeService()
        let s = shared(ctx, autoComplete: true)
        await service.sharedEntered(identifier: s.geofenceIdentifier)
        #expect(s.status == .completed && s.completedAt != nil)
        #expect(fx.statusUpdates == [.completed])
    }

    @Test("受信した依頼: 自動完了の書き込みに失敗したら completed が積まれたまま残る")
    func sharedAutoCompleteFailureQueuesCompleted() async throws {
        let (service, fx, ctx) = try makeService()
        fx.failUpdate = true
        let s = shared(ctx, autoComplete: true)
        await service.sharedEntered(identifier: s.geofenceIdentifier)
        #expect(fx.pending.count == 1)
        if case .completed = fx.pending[0] {} else { Issue.record("completed が積まれるはず") }
        #expect(fx.dequeued.isEmpty)
        #expect(s.status == .completed)
    }

    @Test("受信した依頼: 書き込みに失敗したら未送信キューに積む（通知は出す）")
    func sharedFailureQueues() async throws {
        let (service, fx, ctx) = try makeService()
        fx.failUpdate = true
        let s = shared(ctx)
        await service.sharedEntered(identifier: s.geofenceIdentifier)
        #expect(fx.pending.count == 1)
        if case .fired = fx.pending[0] {} else { Issue.record("fired が積まれるはず") }
        #expect(fx.dequeued.isEmpty)
        #expect(fx.sharedFired.count == 1)
    }

    @Test("受信した依頼: 到着済みの再進入では状態を書き直さず、通知もしない（監視だけ止める）")
    func sharedReentryIgnored() async throws {
        let (service, fx, ctx) = try makeService()
        let s = shared(ctx, status: .fired)
        await service.sharedEntered(identifier: s.geofenceIdentifier)
        #expect(s.status == .fired)
        #expect(fx.statusUpdates.isEmpty && fx.sharedFired.isEmpty && fx.pending.isEmpty)
        #expect(fx.stopped == [s.geofenceIdentifier])
    }

    @Test("通知の「完了」: 保存し、監視（通常・ルート）を止め、画面へ通知する")
    func markDone() async throws {
        let (service, fx, ctx) = try makeService()
        let m = memo(ctx)
        var received: [String] = []
        let token = NotificationCenter.default.addObserver(forName: .geoMemoMarkDone, object: nil, queue: nil) { n in
            if let id = n.object as? String { received.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(service.markDone(id: m.id.uuidString))
        #expect(m.isDone)
        #expect(fx.stopped == [m.id.uuidString] && fx.stoppedRoutes == [m.id.uuidString])
        #expect(fx.widgetReloads == 1)
        #expect(received == [m.id.uuidString])
        // 存在しない・不正な ID は何もしない（監視停止・通知・ウィジェット更新も無し）
        #expect(!service.markDone(id: UUID().uuidString))
        #expect(!service.markDone(id: "x"))
        #expect(fx.stopped.count == 1 && fx.widgetReloads == 1)
    }

    @Test("didMarkDone 単独: 監視（通常・ルート）を止め、ウィジェットと画面へ知らせる")
    func didMarkDoneAlone() throws {
        let (service, fx, _) = try makeService()
        var received: [String] = []
        let token = NotificationCenter.default.addObserver(forName: .geoMemoMarkDone, object: nil, queue: nil) { n in
            if let id = n.object as? String { received.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        service.didMarkDone(id: "abc")
        #expect(fx.stopped == ["abc"] && fx.stoppedRoutes == ["abc"] && fx.widgetReloads == 1)
        #expect(received == ["abc"])
    }

    @Test("run: バックグラウンドタスクを開始し、処理後に未送信を送って 1 回だけ終える")
    func runBeginsAndEnds() async throws {
        let (service, fx, _) = try makeService()
        let bg = FakeBackgroundTasks()
        service.backgroundTasks = bg
        var worked = false
        let done = AsyncStream<Void>.makeStream()
        service.run { worked = true; done.continuation.finish() }
        #expect(bg.begun == ["geomemo-region-event"])
        for await _ in done.stream {}
        for _ in 0..<50 where bg.ended.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(worked)
        #expect(fx.drainCount == 1)
        #expect(bg.ended.count == 1)
    }

    @Test("run: 時間切れで終えたあと、処理が終わっても二重に終えない")
    func runExpiration() async throws {
        let (service, _, _) = try makeService()
        let bg = FakeBackgroundTasks()
        service.backgroundTasks = bg
        let gate = AsyncStream<Void>.makeStream()
        let finished = AsyncStream<Void>.makeStream()
        service.run {
            for await _ in gate.stream {}
            finished.continuation.finish()
        }
        bg.expiration?()
        #expect(bg.ended.count == 1)
        gate.continuation.finish()
        for await _ in finished.stream {}
        try? await Task.sleep(for: .milliseconds(100))
        #expect(bg.ended.count == 1)
    }

    @Test("handleEntered/Exited/SharedEntered はサービスの処理を走らせる")
    func handlersRun() async throws {
        let (service, fx, ctx) = try makeService()
        service.backgroundTasks = FakeBackgroundTasks()
        let m = memo(ctx)
        service.handleEntered(memoID: m.id.uuidString)
        for _ in 0..<100 where fx.immediate.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(fx.immediate == [m.id.uuidString])
    }
}

// MARK: - デリゲートからサービスへの振り分け

@MainActor
@Suite("LocationManager 領域イベントの振り分け", .serialized)
struct RegionDispatchTests {
    private func region(_ id: String) -> CLCircularRegion {
        CLCircularRegion(center: CLLocationCoordinate2D(latitude: 35.68, longitude: 139.76), radius: 100, identifier: id)
    }

    private func makeManager(progress: [String: Int] = [:], counts: [String: Int] = [:]) -> (LocationManager, FakeHandler) {
        UserDefaults.standard.set(progress, forKey: "routeProgress")
        UserDefaults.standard.set(counts, forKey: "routeWaypointCounts")
        let lm = LocationManager()
        let handler = FakeHandler()
        lm.eventHandler = handler
        // 保存先（実ストア）を開く Live Activity の処理は、ここでは呼ばない
        lm.triggerLiveActivity = { _ in }
        lm.updateRouteLiveActivity = { _, _, _ in }
        return (lm, handler)
    }

    private func cleanUp() {
        UserDefaults.standard.removeObject(forKey: "routeProgress")
        UserDefaults.standard.removeObject(forKey: "routeWaypointCounts")
    }

    @Test("通常の領域: 入ったら memoID で、出たら memoID で渡す")
    func normal() {
        defer { cleanUp() }
        let (lm, handler) = makeManager()
        let id = UUID().uuidString
        lm.locationManager(CLLocationManager(), didEnterRegion: region(id))
        lm.locationManager(CLLocationManager(), didExitRegion: region(id))
        #expect(handler.entered == [id] && handler.exited == [id])
    }

    @Test("受信した依頼の領域: 入ったら識別子で渡し、出たときは何もしない")
    func shared() {
        defer { cleanUp() }
        let (lm, handler) = makeManager()
        let id = "\(SharedMemo.geofencePrefix)\(UUID().uuidString)"
        lm.locationManager(CLLocationManager(), didEnterRegion: region(id))
        lm.locationManager(CLLocationManager(), didExitRegion: region(id))
        #expect(handler.shared == [id] && handler.entered.isEmpty && handler.exited.isEmpty)
    }

    @Test("ルート: 最後の経由地に入ったときだけ、メモの ID で渡す")
    func routeFinalWaypoint() {
        defer { cleanUp() }
        let memo = UUID().uuidString
        let (lm, handler) = makeManager(progress: [memo: 1], counts: [memo: 3])
        // 順序が違う（まだ 2 番目を待っている）→ 何もしない
        lm.locationManager(CLLocationManager(), didEnterRegion: region("\(memo)|wp|2"))
        #expect(handler.entered.isEmpty)
        // 2 番目 → 次へ（まだ発火しない）
        lm.locationManager(CLLocationManager(), didEnterRegion: region("\(memo)|wp|1"))
        #expect(handler.entered.isEmpty)
        // 最後 → 発火
        lm.locationManager(CLLocationManager(), didEnterRegion: region("\(memo)|wp|2"))
        #expect(handler.entered == [memo])
        // ルートの退出は無視
        lm.locationManager(CLLocationManager(), didExitRegion: region("\(memo)|wp|2"))
        #expect(handler.exited.isEmpty)
    }
}

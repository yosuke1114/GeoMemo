import Foundation
import SwiftData
import CloudKit
import UIKit
import WidgetKit

// 領域に入った・出たときの処理（通知・滞在・遅延・受信した依頼の到着の書き込み・通知からの「完了」）。
// 画面（SwiftUI）に頼らない。アプリが終了した状態から位置イベントでバックグラウンド起動され、
// 画面が作られなくても動く。判断は純粋な `RegionEventPlanner`、副作用は `RegionEventEffects` に分けてある。

// MARK: - 純粋ロジック

/// メモの発火の判断に使う値（SwiftData のモデルから写す）。
nonisolated struct MemoTriggerState: Equatable, Sendable {
    var title: String
    var note: String
    var notifyOnEntry: Bool
    var notifyOnExit: Bool
    var isDone: Bool
    var deadline: Date?
    var timeWindowStart: Int?
    var timeWindowEnd: Int?
    var activeDays: [Int]?
    var dwellMinutes: Int?
    var exitDelayMinutes: Int?
}

/// 期限・時間帯・曜日の条件。`LocationManager.shouldNotify(for:)` と同じ判定。
nonisolated enum TriggerConditions {
    nonisolated static func isSatisfied(
        deadline: Date?, timeWindowStart: Int?, timeWindowEnd: Int?, activeDays: [Int]?,
        now: Date, calendar: Calendar
    ) -> Bool {
        if let deadline, now > deadline { return false }
        if let start = timeWindowStart, let end = timeWindowEnd {
            let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
            if minutes < start || minutes > end { return false }
        }
        // Calendar.weekday: 1=日 … 7=土 → 0=日 … 6=土
        if let days = activeDays {
            let weekday = calendar.component(.weekday, from: now) - 1
            if !days.contains(weekday) { return false }
        }
        return true
    }
}

nonisolated enum RegionEventPlanner {
    enum EntryAction: Equatable, Sendable {
        case none
        case immediate
        case dwell(minutes: Int)
    }

    enum ExitAction: Equatable, Sendable {
        case none
        /// `delayMinutes` が nil なら即通知。
        case notify(delayMinutes: Int?)
    }

    enum SharedFireAction: Equatable, Sendable {
        /// 監視中ではない（到着済み・完了・取り消し後の再進入）。状態は書き直さず、監視だけ止める。
        case stopOnly
        /// 発火する。`completes` が true（自動完了）なら fired を飛ばして completed を一度だけ書く。
        case fire(completes: Bool)
    }

    nonisolated static func entry(_ s: MemoTriggerState, now: Date, calendar: Calendar) -> EntryAction {
        guard s.notifyOnEntry, !s.isDone, satisfied(s, now, calendar) else { return .none }
        if let dwell = s.dwellMinutes { return .dwell(minutes: dwell) }
        return .immediate
    }

    nonisolated static func exit(_ s: MemoTriggerState, now: Date, calendar: Calendar) -> ExitAction {
        guard s.notifyOnExit, !s.isDone, satisfied(s, now, calendar) else { return .none }
        return .notify(delayMinutes: s.exitDelayMinutes)
    }

    nonisolated static func sharedFire(isActive: Bool, autoComplete: Bool) -> SharedFireAction {
        isActive ? .fire(completes: autoComplete) : .stopOnly
    }

    private nonisolated static func satisfied(_ s: MemoTriggerState, _ now: Date, _ calendar: Calendar) -> Bool {
        TriggerConditions.isSatisfied(
            deadline: s.deadline, timeWindowStart: s.timeWindowStart, timeWindowEnd: s.timeWindowEnd,
            activeDays: s.activeDays, now: now, calendar: calendar)
    }
}

// MARK: - 副作用

@MainActor
protocol RegionEventEffects {
    func scheduleImmediate(title: String, body: String, memoID: String) async
    func scheduleDwell(title: String, body: String, memoID: String, minutes: Int) async
    func scheduleExit(title: String, body: String, memoID: String, delayMinutes: Int?) async
    func cancelDwell(memoID: String)
    func scheduleSharedFired(memoTitle: String, requesterName: String, sharedID: String) async
    func updateSharedStatus(recordID: CKRecord.ID, status: ShareStatus, date: Date) async throws
    func enqueuePending(_ event: PendingShareEvent)
    func stopMonitoring(identifier: String)
    func stopMonitoringRoute(memoID: String)
    /// CloudKit への書き込みに成功した未送信イベントを外す。
    func dequeuePending(_ event: PendingShareEvent)
    /// 溜まっている未送信イベントを送る（領域イベントのたびに試す）。
    func drainPending() async
    func reloadWidgets()
    /// 入れ替えの前に現在地を取る（直近のものがあればそれ）。
    func refreshLocationForRotation() async
    /// 近い順に監視を入れ替える（`GeofenceReconciler.reconcile`）。
    func reconcileGeofences(memos: [GeoMemo], sharedMemos: [SharedMemo])
    /// 登録直後の状態確認（`requestState`）の結果が届くのを、短い上限まで待つ。
    func waitForPendingStateChecks() async
}

extension RegionEventEffects {
    func waitForPendingStateChecks() async {}
    func refreshLocationForRotation() async {}
    func reconcileGeofences(memos: [GeoMemo], sharedMemos: [SharedMemo]) {}
}

@MainActor
struct LiveRegionEventEffects: RegionEventEffects {
    func scheduleImmediate(title: String, body: String, memoID: String) async {
        await NotificationManager.shared.scheduleImmediateNotification(title: title, body: body, memoID: memoID)
    }
    func scheduleDwell(title: String, body: String, memoID: String, minutes: Int) async {
        await NotificationManager.shared.scheduleDwellNotification(
            title: title, body: body, memoID: memoID, dwellMinutes: minutes)
    }
    func scheduleExit(title: String, body: String, memoID: String, delayMinutes: Int?) async {
        await NotificationManager.shared.scheduleExitNotification(
            title: title, body: body, memoID: memoID, delayMinutes: delayMinutes)
    }
    func cancelDwell(memoID: String) {
        NotificationManager.shared.cancelDwellNotification(memoID: memoID)
    }
    func scheduleSharedFired(memoTitle: String, requesterName: String, sharedID: String) async {
        await NotificationManager.shared.scheduleSharedMemoFiredNotification(
            memoTitle: memoTitle, requesterName: requesterName, sharedID: sharedID)
    }
    func updateSharedStatus(recordID: CKRecord.ID, status: ShareStatus, date: Date) async throws {
        try await CKShareService.shared.updateStatus(recordID: recordID, status: status, date: date)
    }
    func enqueuePending(_ event: PendingShareEvent) {
        PendingEventQueue.shared.enqueue(event)
    }
    func stopMonitoring(identifier: String) {
        LocationManager.shared.stopMonitoring(memoID: identifier)
    }
    func stopMonitoringRoute(memoID: String) {
        LocationManager.shared.stopMonitoringRoute(memoID: memoID)
    }
    func dequeuePending(_ event: PendingShareEvent) {
        PendingEventQueue.shared.dequeue(event)
    }
    func drainPending() async {
        await PendingEventQueue.shared.drain()
    }
    func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
    func refreshLocationForRotation() async {
        _ = await LocationManager.shared.freshLocation()
    }
    func reconcileGeofences(memos: [GeoMemo], sharedMemos: [SharedMemo]) {
        GeofenceReconciler.reconcile(memos: memos, sharedMemos: sharedMemos, reason: .rotation)
    }
    func waitForPendingStateChecks() async {
        await LocationManager.shared.waitForStateChecks()
    }
}

/// `LocationManager` が領域の入退出を渡す先。テストで差し替える。
@MainActor
protocol RegionEventHandling {
    func handleEntered(memoID: String)
    func handleExited(memoID: String)
    func handleSharedEntered(identifier: String)
    /// 入れ替え用の円から出た・大きく動いた。
    func handleRotationTrigger()
}

extension RegionEventHandling {
    func handleRotationTrigger() {}
}

/// バックグラウンドの実行時間の確保（UIKit の `beginBackgroundTask` を包む。テストで差し替える）。
@MainActor
protocol BackgroundTaskControlling {
    /// 開始する。`expiration` は時間切れのときに呼ばれる。
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ id: UIBackgroundTaskIdentifier)
}

@MainActor
struct UIKitBackgroundTasks: BackgroundTaskControlling {
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
    }
    func end(_ id: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(id)
    }
}

// MARK: - サービス

@MainActor
final class RegionEventService: RegionEventHandling {
    static let shared = RegionEventService()

    /// テストで差し替える。通常はアプリのコンテナ（`GeoMemoStore.sharedContainer()`、画面の `@Query` と同じ）。
    var container: ModelContainer?
    var effects: RegionEventEffects
    var backgroundTasks: BackgroundTaskControlling = UIKitBackgroundTasks()
    var now: () -> Date = { Date() }
    var calendar: Calendar = .current

    init(effects: RegionEventEffects = LiveRegionEventEffects(), container: ModelContainer? = nil) {
        self.effects = effects
        self.container = container
    }

    /// 画面の `@Query` と同じコンテキスト。アプリが起動時に `container` を渡す（UI テスト・in-memory でも実ストアを開かない）。
    var mainContext: ModelContext? {
        if let container { return container.mainContext }
        return try? GeoMemoStore.sharedContainer().mainContext
    }

    private func memo(id: String) -> GeoMemo? {
        guard let uuid = UUID(uuidString: id), let context = mainContext else { return nil }
        let descriptor = FetchDescriptor<GeoMemo>(predicate: #Predicate { $0.id == uuid })
        return try? context.fetch(descriptor).first
    }

    private func state(of memo: GeoMemo) -> MemoTriggerState {
        MemoTriggerState(
            title: memo.title, note: memo.note, notifyOnEntry: memo.notifyOnEntry,
            notifyOnExit: memo.notifyOnExit, isDone: memo.isDone, deadline: memo.deadline,
            timeWindowStart: memo.timeWindowStart, timeWindowEnd: memo.timeWindowEnd,
            activeDays: memo.activeDays, dwellMinutes: memo.dwellMinutes, exitDelayMinutes: memo.exitDelayMinutes)
    }

    // MARK: 入った・出た

    func memoEntered(id: String) async {
        guard let memo = memo(id: id) else { return }
        let s = state(of: memo)
        switch RegionEventPlanner.entry(s, now: now(), calendar: calendar) {
        case .none: break
        case .immediate: await effects.scheduleImmediate(title: s.title, body: s.note, memoID: id)
        case .dwell(let minutes): await effects.scheduleDwell(title: s.title, body: s.note, memoID: id, minutes: minutes)
        }
    }

    func memoExited(id: String) async {
        guard let memo = memo(id: id) else { return }
        // 滞在タイマー通知は、退場前に発火していなければ取り消す
        effects.cancelDwell(memoID: id)
        let s = state(of: memo)
        if case .notify(let delay) = RegionEventPlanner.exit(s, now: now(), calendar: calendar) {
            await effects.scheduleExit(title: s.title, body: s.note, memoID: id, delayMinutes: delay)
        }
    }

    /// 受信した依頼の領域に入った（到着）。CloudKit へ状態を書き、書けなければ未送信キューに積む。
    func sharedEntered(identifier: String) async {
        guard let context = mainContext,
              let shared = (try? context.fetch(FetchDescriptor<SharedMemo>()))?
                .first(where: { $0.geofenceIdentifier == identifier }) else { return }
        switch RegionEventPlanner.sharedFire(isActive: shared.status == .active, autoComplete: shared.autoComplete) {
        case .stopOnly:
            effects.stopMonitoring(identifier: identifier)
        case .fire(let completes):
            let date = now()
            shared.firedAt = date
            let finalStatus: ShareStatus = completes ? .completed : .fired
            shared.status = finalStatus
            if completes { shared.completedAt = date }
            let owner = shared.zoneOwnerName
            let event: PendingShareEvent = completes
                ? .completed(ckRecordName: shared.ckRecordName, zoneOwnerName: owner, completedAt: date)
                : .fired(ckRecordName: shared.ckRecordName, zoneOwnerName: owner, firedAt: date)
            // ローカル保存と同時に未送信キューへ。CloudKit へ書く前にプロセスが止まっても、
            // 次の機会（起動・前面復帰・領域イベント）に送られ、依頼者へ「到着」が届く。
            effects.enqueuePending(event)
            try? context.save()

            do {
                try await effects.updateSharedStatus(recordID: shared.cloudKitRecordID, status: finalStatus, date: date)
                effects.dequeuePending(event)
            } catch {
                // 失敗時はキューに残る
            }
            await effects.scheduleSharedFired(
                memoTitle: shared.memoTitle, requesterName: shared.requesterName, sharedID: shared.id.uuidString)
            effects.stopMonitoring(identifier: identifier)
        }
    }

    // MARK: 完了（通知の「完了」・ショートカット）

    /// 完了にして保存し、成功したときだけ監視を外し、画面・ウィジェットへ知らせる。
    /// 見つからない・保存に失敗したら何もせず false。
    @discardableResult
    func markDone(id: String) -> Bool {
        guard let memo = memo(id: id), let context = mainContext else { return false }
        memo.isDone = true
        do {
            try context.save()
        } catch {
            memo.isDone = false
            return false
        }
        didMarkDone(id: id)
        return true
    }

    /// 完了が保存されたあとの後始末。監視を外し、画面（触覚・案内）とウィジェットへ知らせる。
    func didMarkDone(id: String) {
        effects.stopMonitoring(identifier: id)
        effects.stopMonitoringRoute(memoID: id)
        effects.reloadWidgets()
        NotificationCenter.default.post(name: .geoMemoMarkDone, object: id)
    }

    // MARK: 領域イベントの受け口（`LocationManager` から）

    func handleEntered(memoID: String) { run { await self.memoEntered(id: memoID) } }
    func handleExited(memoID: String) { run { await self.memoExited(id: memoID) } }
    func handleSharedEntered(identifier: String) { run { await self.sharedEntered(identifier: identifier) } }

    /// 入れ替え用の円の退出・大きな位置の変化。進行中ならもう 1 回は走らせない。
    func handleRotationTrigger() {
        guard !isRotating else { return }
        isRotating = true
        run { await self.rotate() }
    }

    private(set) var isRotating = false

    // MARK: 近い順の入れ替え

    /// 現在地を取り、メモと依頼を読み直して、監視を近い順に入れ替える。画面に頼らない（アプリが終了していても動く）。
    func rotate() async {
        defer { isRotating = false }
        // ウィジェットで完了にした分を先に取り込む（完了したメモを登録し直さない）
        WidgetCompletion.drainPending()
        await effects.refreshLocationForRotation()
        guard let context = mainContext else { return }
        let memos = (try? context.fetch(FetchDescriptor<GeoMemo>())) ?? []
        let shared = (try? context.fetch(FetchDescriptor<SharedMemo>())) ?? []
        effects.reconcileGeofences(memos: memos, sharedMemos: shared)
        // 登録したばかりの領域の「内側にいるか」の結果（進入の通知）が届くまで、実行時間を返さない
        await effects.waitForPendingStateChecks()
    }

    // MARK: バックグラウンドでの実行

    /// 位置イベントのコールバックから呼ぶ。非同期の処理が終わるまで、バックグラウンドの実行時間を確保する。
    /// 処理のあとに、溜まっている未送信イベント（到着・完了）も送ってみる。
    @discardableResult
    func run(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let box = BackgroundTaskBox(controller: backgroundTasks)
        box.id = backgroundTasks.begin(name: "geomemo-region-event") {
            // 時間切れ: これ以上は待てない
            box.end()
        }
        let task = Task { @MainActor in
            await work()
            await effects.drainPending()
            box.end()
        }
        lastRunTask = task
        return task
    }

    /// 最後に始めた処理（テストが完了を待つ）。
    private(set) var lastRunTask: Task<Void, Never>?
}

@MainActor
private final class BackgroundTaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid
    private let controller: BackgroundTaskControlling
    init(controller: BackgroundTaskControlling) { self.controller = controller }

    /// 一度だけ終える（時間切れと通常の終了が重なっても二重に終えない）。
    func end() {
        guard id != .invalid else { return }
        controller.end(id)
        id = .invalid
    }
}

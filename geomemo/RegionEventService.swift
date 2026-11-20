import Foundation
import SwiftData
import CloudKit
import UIKit

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
}

// MARK: - サービス

@MainActor
final class RegionEventService {
    static let shared = RegionEventService()

    /// テストで差し替える。通常はアプリのコンテナ（`GeoMemoStore.sharedContainer()`、画面の `@Query` と同じ）。
    var container: ModelContainer?
    var effects: RegionEventEffects
    var now: () -> Date = { Date() }
    var calendar: Calendar = .current

    init(effects: RegionEventEffects = LiveRegionEventEffects(), container: ModelContainer? = nil) {
        self.effects = effects
        self.container = container
    }

    private var context: ModelContext? {
        if let container { return container.mainContext }
        return try? GeoMemoStore.sharedContainer().mainContext
    }

    private func memo(id: String) -> GeoMemo? {
        guard let uuid = UUID(uuidString: id), let context else { return nil }
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
        guard let context,
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
            try? context.save()   // 先にローカルへ。以降で落ちても再進入で二重に発火しない

            do {
                try await effects.updateSharedStatus(recordID: shared.cloudKitRecordID, status: finalStatus, date: date)
            } catch {
                let owner = shared.zoneOwnerName
                effects.enqueuePending(completes
                    ? .completed(ckRecordName: shared.ckRecordName, zoneOwnerName: owner, completedAt: date)
                    : .fired(ckRecordName: shared.ckRecordName, zoneOwnerName: owner, firedAt: date))
            }
            await effects.scheduleSharedFired(
                memoTitle: shared.memoTitle, requesterName: shared.requesterName, sharedID: shared.id.uuidString)
            effects.stopMonitoring(identifier: identifier)
        }
    }

    // MARK: 完了（通知の「完了」・ショートカット）

    /// 完了にして保存し、監視を外す。見つからなければ何もしない。
    func markDone(id: String) {
        guard let memo = memo(id: id) else { return }
        memo.isDone = true
        try? context?.save()
        didMarkDone(id: id)
    }

    /// 別の経路（ショートカットなど）で完了にしたあとの後始末。監視を外し、画面へ知らせる（触覚・案内の更新）。
    func didMarkDone(id: String) {
        effects.stopMonitoring(identifier: id)
        effects.stopMonitoringRoute(memoID: id)
        NotificationCenter.default.post(name: .geoMemoMarkDone, object: id)
    }

    // MARK: バックグラウンドでの実行

    /// 位置イベントのコールバックから呼ぶ。非同期の処理が終わるまで、バックグラウンドの実行時間を確保する。
    func run(_ work: @escaping @MainActor () async -> Void) {
        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "geomemo-region-event") {
            // 時間切れ: これ以上は待てない
            MainActor.assumeIsolated { box.end() }
        }
        Task { @MainActor in
            await work()
            box.end()
        }
    }
}

@MainActor
private final class BackgroundTaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

@preconcurrency import ActivityKit  // Activity が Sendable でないため（Swift 6 の sending 診断を回避）
import SwiftData
import Foundation
import os

@MainActor
class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var currentActivity: Activity<GeoMemoActivityAttributes>?
    /// 終了を頼んだ Activity の id（まだ一覧に生きて見えても、引き継がない）。
    private var endingIDs: Set<String> = []
    /// このプロセスの間に、ユーザーがロック画面で消した（または許可の確認で「許可しない」を選んだ）。
    /// その間は件数の変化・前面への復帰で出し直さない（消したものがすぐ戻ってくるのは不自然なため）。
    /// プロセスの中だけで覚えるので、次の起動から再開する。
    private var userDismissedInThisProcess = false

    private nonisolated static let logger = Logger(subsystem: "com.yokuro.geomemo", category: "LiveActivity")

    /// 監視中の Activity に設定する staleDate（8 時間）。Apple の 12 時間制限の手前で
    /// stale に倒して force-kill による UX 劣化を防ぐ。アプリ起動時に startMonitoring が
    /// 再度呼ばれて延長される想定。
    private var monitoringStaleDate: Date { Date().addingTimeInterval(8 * 60 * 60) }

    // MARK: - State Factories
    // ContentState は idle / approaching / triggered / route / end の 5 形式しかないので
    // factory に集約してコールサイトの 11-field literal 重複を消す。
    // memoLocation は idle 時には未使用（view 側は monitoredCount から組み立てる）。

    private typealias State = GeoMemoActivityAttributes.ContentState

    private static func idleState(monitoredCount: Int) -> State {
        State(
            isTriggered: false, memoTitle: "", memoLocation: "", memoColorIndex: 0,
            triggeredAt: nil,
            routeCurrentWaypoint: nil, routeTotalWaypoints: nil,
            approachingTitle: nil, approachingDistance: nil, approachingColorIndex: 0,
            monitoredCount: monitoredCount
        )
    }

    private static func triggeredState(memo: (title: String, locationName: String, colorIndex: Int), monitoredCount: Int) -> State {
        State(
            isTriggered: true, memoTitle: memo.title, memoLocation: memo.locationName, memoColorIndex: memo.colorIndex,
            triggeredAt: Date(),
            routeCurrentWaypoint: nil, routeTotalWaypoints: nil,
            approachingTitle: nil, approachingDistance: nil, approachingColorIndex: 0,
            monitoredCount: monitoredCount
        )
    }

    private static func approachingState(memo: (title: String, colorIndex: Int), distance: Int, monitoredCount: Int) -> State {
        State(
            isTriggered: false, memoTitle: "", memoLocation: "", memoColorIndex: 0,
            triggeredAt: nil,
            routeCurrentWaypoint: nil, routeTotalWaypoints: nil,
            approachingTitle: memo.title, approachingDistance: distance, approachingColorIndex: memo.colorIndex,
            monitoredCount: monitoredCount
        )
    }

    private static func routeState(memo: (title: String, locationName: String, colorIndex: Int), current: Int, total: Int, monitoredCount: Int) -> State {
        State(
            isTriggered: false, memoTitle: memo.title, memoLocation: memo.locationName, memoColorIndex: memo.colorIndex,
            triggeredAt: nil,
            routeCurrentWaypoint: current, routeTotalWaypoints: total,
            approachingTitle: nil, approachingDistance: nil, approachingColorIndex: 0,
            monitoredCount: monitoredCount
        )
    }

    private static let endState: State = State(
        isTriggered: false, memoTitle: "", memoLocation: "", memoColorIndex: 0,
        triggeredAt: nil,
        routeCurrentWaypoint: nil, routeTotalWaypoints: nil,
        approachingTitle: nil, approachingDistance: nil, approachingColorIndex: 0,
        monitoredCount: 0
    )

    // MARK: - Start Monitoring

    /// 監視中のメモの数を Live Activity に出す。0 件なら終える。
    ///
    /// 呼ぶのは、起動時（地図の表示）・監視するメモの数が変わったとき・前面に戻ったとき（`MapTabView`）。
    /// 前面に戻ったときは、バックグラウンドで 0 → N 件になって始められなかった分の再試行と、staleDate の延長を兼ねる。
    /// - Parameter resetToIdle: 監視中の表示に戻す（起動時だけ）。それ以外は今の表示（到着・接近・ルート）のまま件数だけ変える。
    func startMonitoring(count: Int, resetToIdle: Bool = false) {
        let plan = resolve(count: count)
        switch plan.action {
        case .none:
            if count > 0 && userDismissedInThisProcess {
                Self.logger.info("Live Activity was dismissed by the user; not restarting until next launch")
            }
        case .update:
            guard let activity = currentActivity else { return }
            let content: ActivityContent<State>
            if resetToIdle {
                content = ActivityContent(state: Self.idleState(monitoredCount: count), staleDate: monitoringStaleDate)
            } else {
                var state = activity.content.state
                state.monitoredCount = count
                // 監視中の表示なら staleDate を延ばす。到着などの表示は、その表示の staleDate のまま
                let staleDate = Self.isIdle(state) ? monitoringStaleDate : activity.content.staleDate
                content = ActivityContent(state: state, staleDate: staleDate)
            }
            Task { await activity.update(content) }
        case .request:
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                Self.logger.info("Live Activity is disabled by the user or the system")
                return
            }
            do {
                currentActivity = try Activity.request(
                    attributes: GeoMemoActivityAttributes(monitoredCount: count),
                    content: ActivityContent(state: Self.idleState(monitoredCount: count), staleDate: monitoringStaleDate)
                )
            } catch {
                Self.logger.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func isIdle(_ state: State) -> Bool {
        !state.isTriggered && state.approachingTitle == nil && state.routeCurrentWaypoint == nil
    }

    // MARK: - Trigger Memo

    /// Update the Live Activity to show a triggered memo.
    /// Can be called from the background when a geofence event fires.
    nonisolated func triggerMemo(id: String) {
        guard let memo = lookupMemo(id: id) else { return }

        Task { @MainActor in
            // バックグラウンドで起動された（地図の画面が無い）ときも、前の起動で始めた Activity を引き継いで更新する
            guard let activity = resolveActivity() else { return }
            let state = Self.triggeredState(memo: memo, monitoredCount: activity.content.state.monitoredCount)
            await activity.update(
                ActivityContent(state: state, staleDate: Date().addingTimeInterval(60 * 30)),
                alertConfiguration: AlertConfiguration(
                    title: "\(memo.title)",
                    body: "\(memo.locationName)",
                    sound: .default
                )
            )
        }
    }

    // MARK: - Approaching (v1.1)

    /// 接近中メモのDynamic Island表示を更新する。
    /// - Parameters:
    ///   - memoID: 接近中メモのUUID文字列。nil を渡すと接近表示をクリアする。
    ///   - distance: ジオフェンス境界までの距離（メートル）
    func updateApproaching(memoID: String?, distance: Int = 0) {
        guard let activity = resolveActivity() else { return }
        let count = activity.content.state.monitoredCount
        let state: State
        if let memoID, let memo = lookupMemo(id: memoID) {
            state = Self.approachingState(
                memo: (title: memo.title, colorIndex: memo.colorIndex),
                distance: distance,
                monitoredCount: count
            )
        } else {
            // 接近解除 → 通常のモニタリング表示に戻す
            state = Self.idleState(monitoredCount: count)
        }
        Task {
            await activity.update(ActivityContent(state: state, staleDate: monitoringStaleDate))
        }
    }

    // MARK: - Route Progress

    /// Update the Live Activity to show route waypoint progress.
    /// Call this when a waypoint is passed but the route is not yet complete.
    /// - Parameters:
    ///   - memoID: The memo's UUID string
    ///   - current: The next waypoint index (1-based, e.g. 2 means "waiting for WP2")
    ///   - total: Total number of waypoints in the route
    nonisolated func updateRouteProgress(memoID: String, current: Int, total: Int) {
        guard let memo = lookupMemo(id: memoID) else { return }

        Task { @MainActor in
            guard let activity = resolveActivity() else { return }
            let state = Self.routeState(
                memo: memo,
                current: current,
                total: total,
                monitoredCount: activity.content.state.monitoredCount
            )
            await activity.update(ActivityContent(state: state, staleDate: monitoringStaleDate))
        }
    }

    // MARK: - Adopt / End

    /// 今の Activity を返す（引き継ぎ込み）。`currentActivity` を直接使わず、更新の前には必ずこれを通す。
    private func resolveActivity() -> Activity<GeoMemoActivityAttributes>? {
        resolve(count: nil)
        return currentActivity
    }

    /// システムに残っている Activity から、引き継ぐもの・終えるものを決めて、そのとおりにする（判断は `LiveActivityPlan`）。
    ///
    /// `currentActivity` はプロセスが終わると失われるので、引き継がないと起動のたびに新しい Activity が増え、
    /// 古いものは更新されないまま残る（12 時間で消えるまで）。
    @discardableResult
    private func resolve(count: Int?) -> LiveActivityPlan {
        // 今の Activity が終わっていれば外す。終了を頼んでいないのに消えていれば、ユーザーがロック画面で消した
        // （許可の確認で「許可しない」を選んだときも同じ）。そのプロセスの間は出し直さない。
        if let current = currentActivity, !Self.isAlive(current.activityState) {
            if current.activityState == .dismissed && !endingIDs.contains(current.id) {
                userDismissedInThisProcess = true
            }
            currentActivity = nil
        }
        var all = Activity<GeoMemoActivityAttributes>.activities
        if let current = currentActivity, !all.contains(where: { $0.id == current.id }) {
            all.append(current)
        }
        let plan = LiveActivityPlan.make(
            existing: all.map { LiveActivityPlan.Existing(id: $0.id, isAlive: Self.isAlive($0.activityState)) },
            currentID: currentActivity?.id,
            count: count,
            endingIDs: endingIDs,
            userDismissed: userDismissedInThisProcess)
        currentActivity = all.first { $0.id == plan.keepID }
        for activity in all where plan.endIDs.contains(activity.id) {
            end(activity)
        }
        return plan
    }

    private func end(_ activity: Activity<GeoMemoActivityAttributes>) {
        endingIDs.insert(activity.id)
        Task {
            await activity.end(ActivityContent(state: Self.endState, staleDate: nil), dismissalPolicy: .immediate)
        }
    }

    private static func isAlive(_ state: ActivityState) -> Bool {
        state != .ended && state != .dismissed
    }

    // MARK: - Memo Lookup

    /// Look up a memo from the shared SwiftData store by its UUID string.
    /// This works independently of SwiftUI views, so it can be called from the background.
    nonisolated private func lookupMemo(id: String) -> (title: String, locationName: String, colorIndex: Int)? {
        // CR-7: 共有コンテナを使い回して初期化コストを抑える。
        guard let container = try? GeoMemoStore.sharedContainer() else { return nil }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<GeoMemo>(
            predicate: #Predicate { $0.id.uuidString == id }
        )
        // 存在しない・完了済み（Watch で完了したメモなど）は対象にしない
        guard let memo = (try? context.fetch(descriptor))?.first, !memo.isDone else { return nil }
        return (title: memo.title, locationName: memo.locationName, colorIndex: memo.colorIndex)
    }
}

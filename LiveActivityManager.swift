@preconcurrency import ActivityKit  // Activity が Sendable でないため（Swift 6 の sending 診断を回避）
import SwiftData
import Foundation
import os

@MainActor
class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var currentActivity: Activity<GeoMemoActivityAttributes>?

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

    /// Start a Live Activity showing that GeoMemo is monitoring nearby memos.
    /// Call this when the app launches and has active memos.
    ///
    /// 起動時（地図の表示）と、監視するメモの数が変わったとき（`MapTabView`）に呼ぶ。0 件になったら終える。
    /// 前回の起動で始めた Activity が残っていれば引き継ぎ、余分なものは終える（起動のたびに増えないように）。
    func startMonitoring(count: Int) {
        adoptExistingActivities()
        guard count > 0 else {
            endActivity()
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.logger.info("Live Activity is disabled by the user or the system")
            return
        }

        let state = Self.idleState(monitoredCount: count)

        // If already running, just update the count
        if let activity = currentActivity {
            Task {
                await activity.update(ActivityContent(state: state, staleDate: monitoringStaleDate))
            }
            return
        }

        let attributes = GeoMemoActivityAttributes(monitoredCount: count)
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: monitoringStaleDate)
            )
            currentActivity = activity
        } catch {
            Self.logger.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Trigger Memo

    /// Update the Live Activity to show a triggered memo.
    /// Can be called from the background when a geofence event fires.
    nonisolated func triggerMemo(id: String) {
        guard let memo = lookupMemo(id: id) else { return }

        Task { @MainActor in
            guard let activity = currentActivity else { return }
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
        guard let activity = currentActivity else { return }
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
            guard let activity = currentActivity else { return }
            let state = Self.routeState(
                memo: memo,
                current: current,
                total: total,
                monitoredCount: activity.content.state.monitoredCount
            )
            await activity.update(ActivityContent(state: state, staleDate: monitoringStaleDate))
        }
    }

    // MARK: - End Activity

    func endActivity() {
        adoptExistingActivities()
        guard let activity = currentActivity else { return }
        Task {
            await activity.end(ActivityContent(state: Self.endState, staleDate: nil), dismissalPolicy: .immediate)
        }
        currentActivity = nil
    }

    // MARK: - Adopt

    /// システムに残っている Activity（前回の起動で始めたもの）を引き継ぐ。
    /// `currentActivity` はプロセスが終わると失われるので、引き継がないと起動のたびに新しい Activity が増え、
    /// 古いものは更新されないまま残る（12 時間で消えるまで）。続いているものを 1 つ残し、ほかは終える。
    private func adoptExistingActivities() {
        let existing = Activity<GeoMemoActivityAttributes>.activities
        if currentActivity == nil {
            // 終わっていないもの（表示中・古くなった・許可の確認待ちなど）を引き継ぐ
            currentActivity = existing.first { $0.activityState != .ended && $0.activityState != .dismissed }
        }
        let keepID = currentActivity?.id
        for extra in existing where extra.id != keepID {
            Task {
                await extra.end(ActivityContent(state: Self.endState, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
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

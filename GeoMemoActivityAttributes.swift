import ActivityKit
import Foundation

struct GeoMemoActivityAttributes: ActivityAttributes {
    /// Number of memos being monitored
    var monitoredCount: Int

    struct ContentState: Codable, Hashable {
        var isTriggered: Bool
        var memoTitle: String
        var memoLocation: String
        var memoColorIndex: Int
        var triggeredAt: Date?
        /// Route progress: next waypoint index to reach (1-based display)
        var routeCurrentWaypoint: Int?
        /// Total number of waypoints in the route
        var routeTotalWaypoints: Int?
    }
}

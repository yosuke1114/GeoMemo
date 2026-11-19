import ActivityKit
import Foundation

/// アプリ target は default actor isolation = MainActor のため、明示的に nonisolated にして
/// ActivityKit（@concurrent コンテキスト）から ActivityAttributes 準拠を使えるようにする。
nonisolated struct GeoMemoActivityAttributes: ActivityAttributes {
    /// 後方互換のため残置（activity の attributes は不変なので最新値の参照には使えない）。
    /// 表示には ContentState.monitoredCount を使うこと。
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

        // MARK: - Approaching (v1.1)
        /// 接近中メモのタイトル（nil = 接近中メモなし）
        var approachingTitle: String?
        /// ジオフェンス境界までの距離（メートル）
        var approachingDistance: Int?
        /// 接近中メモのカラーインデックス
        var approachingColorIndex: Int = 0

        // MARK: - Monitored count (v2.0+)
        /// 監視中メモ数。ContentState に置くことで activity が起動済みでも update 可能。
        /// 旧 activity（v1.x）からの decode 互換のため default を持たせる。
        var monitoredCount: Int = 0
    }
}

import Foundation
import CoreLocation
import Combine

extension Notification.Name {
    static let didEnterGeoMemoRegion = Notification.Name("didEnterGeoMemoRegion")
    static let didExitGeoMemoRegion  = Notification.Name("didExitGeoMemoRegion")
}

class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()

    private let manager = CLLocationManager()

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var location: CLLocation?

    // MARK: - Route Progress (UserDefaults で永続化、バックグラウンド起動時も維持)
    /// memoID → 次に通過すべき waypoint index
    private var routeProgress: [String: Int] {
        get { UserDefaults.standard.object(forKey: "routeProgress") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "routeProgress") }
    }
    /// memoID → waypoint 総数
    private var routeWaypointCounts: [String: Int] {
        get { UserDefaults.standard.object(forKey: "routeWaypointCounts") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "routeWaypointCounts") }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    /// Request authorization and one-shot location if already authorized.
    /// Call this early (e.g. during splash) to overlap permission flow with splash animation.
    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            manager.requestLocation()
        case .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    /// Request a fresh one-shot location update (e.g. for the "center on me" button).
    func refreshLocation() {
        guard manager.authorizationStatus == .authorizedWhenInUse ||
              manager.authorizationStatus == .authorizedAlways else { return }
        manager.requestLocation()
    }

    func startMonitoring(region: CLCircularRegion) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            print("Geofencing is not available on this device")
            return
        }
        manager.startMonitoring(for: region)
    }

    func stopMonitoring(memoID: String) {
        if let region = manager.monitoredRegions.first(where: { $0.identifier == memoID }) {
            manager.stopMonitoring(for: region)
        }
    }

    // MARK: - Route Trigger Monitoring

    /// Waypoint identifier format: "{memoID}|wp|{index}"
    func startMonitoringRoute(for memo: GeoMemo) {
        let waypoints = memo.routeWaypoints
        guard waypoints.count >= 2 else { return }

        let memoID = memo.id.uuidString
        // 進捗・総数を記録（バックグラウンド起動後も didEnterRegion で参照できるよう永続化）
        var progress = routeProgress
        progress[memoID] = 0
        routeProgress = progress

        var counts = routeWaypointCounts
        counts[memoID] = waypoints.count
        routeWaypointCounts = counts

        for (index, waypoint) in waypoints.enumerated() {
            let region = CLCircularRegion(
                center: waypoint.coordinate,
                radius: memo.radius,
                identifier: "\(memoID)|wp|\(index)"
            )
            region.notifyOnEntry = true
            region.notifyOnExit = false
            startMonitoring(region: region)
        }
    }

    func stopMonitoringRoute(memoID: String) {
        let prefix = "\(memoID)|wp|"
        for region in manager.monitoredRegions where region.identifier.hasPrefix(prefix) {
            manager.stopMonitoring(for: region)
        }
        // 進捗・総数をクリア
        var progress = routeProgress
        progress.removeValue(forKey: memoID)
        routeProgress = progress

        var counts = routeWaypointCounts
        counts.removeValue(forKey: memoID)
        routeWaypointCounts = counts
    }

    /// Stop all currently monitored regions.
    func stopAllMonitoring() {
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
    }

    /// Number of currently monitored regions.
    var monitoredRegionCount: Int {
        manager.monitoredRegions.count
    }

    /// Check whether a memo's trigger conditions are currently satisfied.
    func shouldNotify(for memo: GeoMemo) -> Bool {
        let now = Date()
        let calendar = Calendar.current

        // 期限チェック
        if let deadline = memo.deadline {
            if now > deadline { return false }
        }

        // 時間帯チェック
        if let start = memo.timeWindowStart,
           let end = memo.timeWindowEnd {
            let currentMinutes =
                calendar.component(.hour, from: now) * 60 +
                calendar.component(.minute, from: now)
            if currentMinutes < start || currentMinutes > end { return false }
        }

        // 曜日チェック (Calendar.weekday: 1=日, 2=月, ..., 7=土 → 0=日, 1=月, ..., 6=土)
        if let days = memo.activeDays {
            let weekday = calendar.component(.weekday, from: now) - 1
            if !days.contains(weekday) { return false }
        }

        return true
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location request failed: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion else { return }
        let identifier = circularRegion.identifier

        if let separatorRange = identifier.range(of: "|wp|") {
            // ── Route waypoint ──────────────────────────────────────────
            let memoID  = String(identifier[..<separatorRange.lowerBound])
            let indexStr = String(identifier[separatorRange.upperBound...])
            guard let enteredIndex = Int(indexStr) else { return }

            var progress = routeProgress
            let total    = routeWaypointCounts[memoID] ?? 0

            // 最初のウェイポイント(0)に入ったら必ず進捗をリセット（ルート再開）
            if enteredIndex == 0 {
                progress[memoID] = 0
                routeProgress = progress
            }

            let expected = progress[memoID] ?? 0

            // 順序が違うウェイポイントは無視
            guard enteredIndex == expected else { return }

            let next = expected + 1
            if total > 0 && next >= total {
                // ── 全ウェイポイント通過 → 発火 ──────────────────────
                progress.removeValue(forKey: memoID)
                routeProgress = progress
                NotificationCenter.default.post(name: .didEnterGeoMemoRegion, object: memoID)
                LiveActivityManager.shared.triggerMemo(id: memoID)
            } else {
                // 次のウェイポイントを待つ
                progress[memoID] = next
                routeProgress = progress
                // Live Activity にルート進行状況を反映（次に向かうWP番号を1始まりで表示）
                LiveActivityManager.shared.updateRouteProgress(memoID: memoID, current: next + 1, total: total)
            }
        } else {
            // ── 通常ジオフェンス ─────────────────────────────────────
            let memoID = identifier
            NotificationCenter.default.post(name: .didEnterGeoMemoRegion, object: memoID)
            LiveActivityManager.shared.triggerMemo(id: memoID)
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion else { return }
        let identifier = circularRegion.identifier
        // ルートウェイポイントの退出は無視
        guard !identifier.contains("|wp|") else { return }
        NotificationCenter.default.post(name: .didExitGeoMemoRegion, object: identifier)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        print("Monitoring failed for region: \(region?.identifier ?? "unknown") with error: \(error.localizedDescription)")
    }
}

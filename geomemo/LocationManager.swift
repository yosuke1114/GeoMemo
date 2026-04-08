import Foundation
import CoreLocation
import Combine

extension Notification.Name {
    static let didEnterGeoMemoRegion = Notification.Name("didEnterGeoMemoRegion")
}

class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()

    private let manager = CLLocationManager()

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var location: CLLocation?

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
        NotificationCenter.default.post(name: .didEnterGeoMemoRegion, object: circularRegion.identifier)

        // Update Live Activity in Dynamic Island
        LiveActivityManager.shared.triggerMemo(id: circularRegion.identifier)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        // Currently not used, but can be implemented if needed
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        print("Monitoring failed for region: \(region?.identifier ?? "unknown") with error: \(error.localizedDescription)")
    }
}

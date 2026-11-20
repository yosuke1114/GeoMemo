import Foundation
import CoreLocation

/// 監視（ジオフェンス）の登録まわり。地図と「通知のチェック」の両方から使う。
@MainActor
enum GeofenceRegistrar {
    /// 監視したいジオフェンスの数。ルートは経由地ごとに 1 件、受信した有効な依頼も 1 件。
    /// 経由地が 2 未満のルートは登録されない（LocationManager.startMonitoringRoute）ので数えない。
    static func requiredRegionCount(memos: [GeoMemo], sharedMemos: [SharedMemo]) -> Int {
        let own = memos.filter { !$0.isDone }.reduce(0) {
            $0 + MonitoringLimitState.regionCount(isRoute: $1.isRouteTrigger, waypointCount: $1.routeWaypoints.count)
        }
        let received = sharedMemos.filter { !$0.isMyRequest && $0.status == .active }.count
        return own + received
    }

    /// 全部外して登録し直す。上限（20 件）を超えると後ろは登録されないので、
    /// 受信した依頼を先に、自分のメモを後に登録する（`GeofenceRegistrationOrder`）。
    static func reRegisterAll(memos: [GeoMemo], sharedMemos: [SharedMemo]) {
        let locationManager = LocationManager.shared
        locationManager.stopAllMonitoring()
        var registeredRegionCount = 0
        let receivedActive = sharedMemos.filter { !$0.isMyRequest && $0.status == .active }
        let ownActive = memos.filter { !$0.isDone }
        for entry in GeofenceRegistrationOrder.prioritized(received: receivedActive, own: ownActive) {
            switch entry {
            case .received(let shared):
                locationManager.startMonitoring(region: shared.monitoringRegion)
                registeredRegionCount += 1
            case .own(let memo):
                if memo.isRouteTrigger {
                    locationManager.startMonitoringRoute(for: memo)
                    registeredRegionCount += memo.routeWaypoints.count
                } else {
                    let region = CLCircularRegion(
                        center: CLLocationCoordinate2D(latitude: memo.latitude, longitude: memo.longitude),
                        radius: memo.radius,
                        identifier: memo.id.uuidString
                    )
                    region.notifyOnEntry = memo.notifyOnEntry
                    region.notifyOnExit = memo.notifyOnExit
                    locationManager.startMonitoring(region: region)
                    registeredRegionCount += 1
                }
            }
        }
        if registeredRegionCount > LocationManager.maxMonitoredRegions {
            print("⚠️ Geofencing limit warning: \(registeredRegionCount) regions registered (iOS limit is 20)")
        }
    }
}

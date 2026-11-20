import Foundation
import CoreLocation

// 監視（ジオフェンス）の差分での登録。iOS が同時に監視できるのは 20 件までで、
// 受信した依頼を優先し、溢れるのは自分のメモの古いものから、という決まりを実行中にも保つ。
// 全部を登録し直すとルートの進み具合が 0 に戻るので、ここでは足りない分・溢れた分だけを動かす。

/// 優先順に並べた 1 件分（メモ 1 件・依頼 1 件）。ルートは経由地ごとに領域を持つ。
nonisolated struct GeofenceItem: Equatable {
    let key: String
    let regionIDs: [String]
}

nonisolated enum GeofenceReconcilePlanner {
    struct Plan: Equatable {
        /// 外す項目の key（枠を空けるため、または登録する必要がなくなった）。
        var stop: [String] = []
        /// 登録する項目の key。
        var start: [String] = []
        var isEmpty: Bool { stop.isEmpty && start.isEmpty }
    }

    /// `items` は優先順。`monitored` は今登録されている領域の識別子。
    /// どの項目にも属さない領域（消したメモの領域が残っているなど）は枠を使っているものとして数える。
    /// 項目は領域がすべて収まるときだけ選ぶ（収まらない項目は飛ばし、後ろの小さい項目を入れる）。
    nonisolated static func plan(items: [GeofenceItem], monitored: Set<String>, limit: Int = 20) -> Plan {
        let known = Set(items.flatMap(\.regionIDs))
        let foreign = monitored.subtracting(known).count
        var budget = max(0, limit - foreign)
        var plan = Plan()
        for item in items where !item.regionIDs.isEmpty {
            let wanted = item.regionIDs.count <= budget
            if wanted {
                budget -= item.regionIDs.count
                if item.regionIDs.contains(where: { !monitored.contains($0) }) { plan.start.append(item.key) }
            } else if item.regionIDs.contains(where: { monitored.contains($0) }) {
                plan.stop.append(item.key)
            }
        }
        return plan
    }
}

@MainActor
enum GeofenceReconciler {
    /// 自分のメモの優先順（新しいものが先。溢れるのは古いものから）。
    static func ownByPriority(_ memos: [GeoMemo]) -> [GeoMemo] {
        memos.filter { !$0.isDone }.sorted { $0.createdAt > $1.createdAt }
    }

    private static func ownRegionIDs(_ memo: GeoMemo) -> [String] {
        if memo.isRouteTrigger {
            let count = memo.routeWaypoints.count
            return count >= 2 ? (0..<count).map { "\(memo.id.uuidString)|wp|\($0)" } : []
        }
        return [memo.id.uuidString]
    }

    /// 受信した有効な依頼の変化・自分のメモの増減のあとに呼ぶ。足りない領域を登録し、溢れた分を外す。
    static func reconcile(memos: [GeoMemo], sharedMemos: [SharedMemo]) {
        let lm = LocationManager.shared
        guard LocationAccess(lm.authorizationStatus).isAuthorized else { return }
        let received = sharedMemos.filter { !$0.isMyRequest && $0.status == .active }
        let own = ownByPriority(memos)

        var sharedByKey: [String: SharedMemo] = [:]
        var ownByKey: [String: GeoMemo] = [:]
        var items: [GeofenceItem] = []
        for s in received {
            sharedByKey[s.geofenceIdentifier] = s
            items.append(GeofenceItem(key: s.geofenceIdentifier, regionIDs: [s.geofenceIdentifier]))
        }
        for m in own {
            ownByKey[m.id.uuidString] = m
            items.append(GeofenceItem(key: m.id.uuidString, regionIDs: ownRegionIDs(m)))
        }

        let plan = GeofenceReconcilePlanner.plan(items: items, monitored: lm.monitoredRegionIdentifiers)
        guard !plan.isEmpty else { return }
        // 先に外して枠を空けてから登録する
        for key in plan.stop {
            if sharedByKey[key] != nil {
                lm.stopMonitoring(memoID: key)
            } else if let memo = ownByKey[key] {
                if memo.isRouteTrigger { lm.stopMonitoringRoute(memoID: key) } else { lm.stopMonitoring(memoID: key) }
            }
        }
        for key in plan.start {
            if let s = sharedByKey[key] {
                lm.startMonitoring(region: s.monitoringRegion)
            } else if let memo = ownByKey[key] {
                if memo.isRouteTrigger {
                    lm.startMonitoringRoute(for: memo)
                } else {
                    let region = CLCircularRegion(
                        center: CLLocationCoordinate2D(latitude: memo.latitude, longitude: memo.longitude),
                        radius: memo.radius, identifier: key)
                    region.notifyOnEntry = memo.notifyOnEntry
                    region.notifyOnExit = memo.notifyOnExit
                    lm.startMonitoring(region: region)
                }
            }
        }
    }
}

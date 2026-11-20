import Foundation
import CoreLocation

// 監視（ジオフェンス）の差分での登録。iOS が同時に監視できるのは 20 件までで、
// 受信した依頼を優先し、自分のメモは並びの前（現在地に近い順。`NearestRotation`）から登録する、という決まりを実行中にも保つ。
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
        /// どの項目にも属さない、このアプリが登録した形式の領域（消した・完了したメモの領域など）。外す。
        var stopRegionIDs: [String] = []
        var isEmpty: Bool { stop.isEmpty && start.isEmpty && stopRegionIDs.isEmpty }
    }

    /// `items` は優先順。`monitored` は今登録されている領域の識別子。
    /// どの項目にも属さない領域（消したメモの領域が残っているなど）は枠を使っているものとして数える。
    /// 項目は領域がすべて収まるときだけ選ぶ（収まらない項目は飛ばし、後ろの小さい項目を入れる）。
    nonisolated static func plan(items: [GeofenceItem], monitored: Set<String>, limit: Int = 20) -> Plan {
        let known = Set(items.flatMap(\.regionIDs))
        let unknown = monitored.subtracting(known)
        // 消した・完了したメモ（Watch での操作を含む）の領域は、このアプリの識別子の形式なら外す。
        // 形式に合わないもの（他の機能の領域）は触らず、枠を使っているものとして数える。
        let stale = unknown.filter(isAppRegionIdentifier)
        var budget = max(0, limit - (unknown.count - stale.count))
        var plan = Plan()
        plan.stopRegionIDs = stale.sorted()
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

/// このアプリが登録する領域の識別子の形式か。
/// メモ（UUID）・ルートの経由地（`UUID|wp|番号`）・受信した依頼（`shared_UUID`）に限る。
nonisolated func isAppRegionIdentifier(_ id: String) -> Bool {
    func isUUID(_ s: some StringProtocol) -> Bool { UUID(uuidString: String(s)) != nil }
    if id.hasPrefix(SharedMemo.geofencePrefix) {
        return isUUID(id.dropFirst(SharedMemo.geofencePrefix.count))
    }
    let parts = id.components(separatedBy: "|wp|")
    if parts.count == 2 { return isUUID(parts[0]) && Int(parts[1]) != nil }
    return isUUID(id)
}

@MainActor
enum GeofenceReconciler {
    /// 呼ぶ契機。入れ替え（円の退出・大きな移動）のときだけ、新しく登録した領域の内側にいるかを確かめる。
    enum Reason { case sync, rotation }

    /// 自分のメモの優先順の基本（新しいものが先）。現在地が分かるときは `NearestRotation.order` が近い順に並べ直す。
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

    /// 入れ替えの対象（受信した有効な依頼・未完了の自分のメモ）。
    static func places(memos: [GeoMemo], sharedMemos: [SharedMemo], routeProgress: (String) -> Int = { _ in 0 }) -> [RotationPlace] {
        var places: [RotationPlace] = []
        for s in sharedMemos where !s.isMyRequest && s.status == .active {
            places.append(RotationPlace(
                key: s.geofenceIdentifier, regionIDs: [s.geofenceIdentifier], centers: [s.coordinate],
                radius: max(50, s.memoRadius), createdAt: s.createdAt, isReceived: true))
        }
        for m in ownByPriority(memos) {
            let ids = ownRegionIDs(m)
            let centers = m.isRouteTrigger ? m.routeWaypoints.map(\.coordinate) : [m.coordinate]
            let key = m.id.uuidString
            places.append(RotationPlace(
                key: key, regionIDs: ids, centers: centers, radius: m.radius, createdAt: m.createdAt, isReceived: false,
                isPinned: m.isRouteTrigger && routeProgress(key) >= 1))
        }
        return places
    }

    /// 近い順の入れ替えで、同時に監視に入りうる領域の数（診断で「これ以上入る項目が無い」を見分けるのに使う）。
    static func selectableRegionCount(memos: [GeoMemo], sharedMemos: [SharedMemo]) -> Int {
        let all = places(memos: memos, sharedMemos: sharedMemos)
        let decision = NearestRotation.decide(places: all, anchor: nil, monitoredKeys: [], maxRadius: -1)
        return decision.ordered.filter { decision.selected.contains($0.key) }.reduce(0) { $0 + $1.regionIDs.count }
    }

    /// 受信した有効な依頼の変化・自分のメモの増減・現在地の大きな変化のあとに呼ぶ。
    /// 受信した依頼を先に、自分のメモは現在地に近い順に、足りない領域を登録し、溢れた分を外す。
    /// 監視したい領域が 20 件を超えるときは、19 件＋入れ替え用の円 1 件にする。
    /// 現在地が分からないときは、登録済みの円の中心を基準にし、それも無ければ登録済みの並びを変えない。
    static func reconcile(
        memos: [GeoMemo], sharedMemos: [SharedMemo], reason: Reason = .sync, retryOnUnreliable: Bool = true
    ) {
        let lm = LocationManager.shared
        guard LocationAccess(lm.authorizationStatus).isAuthorized else { return }

        let all = places(memos: memos, sharedMemos: sharedMemos, routeProgress: { lm.routeProgressValue(memoID: $0) })
        var sharedByKey: [String: SharedMemo] = [:]
        var ownByKey: [String: GeoMemo] = [:]
        for s in sharedMemos where !s.isMyRequest && s.status == .active { sharedByKey[s.geofenceIdentifier] = s }
        for m in memos where !m.isDone { ownByKey[m.id.uuidString] = m }

        let monitored = lm.monitoredRegionIdentifiers.subtracting([NearestRotation.circleIdentifier])
        let knownIDs = Set(all.flatMap(\.regionIDs))
        // 他の機能の領域（このアプリの形式でないもの）は枠を使っているものとして数える（planner と同じ）
        let foreign = monitored.subtracting(knownIDs).filter { !isAppRegionIdentifier($0) }.count
        let monitoredKeys = Set(all.filter { $0.regionIDs.contains(where: monitored.contains) }.map(\.key))

        let location = lm.location
        let anchor = location ?? lm.rotationCircle?.location
        let decision = NearestRotation.decide(
            places: all, anchor: anchor, monitoredKeys: monitoredKeys, foreignRegions: foreign,
            maxRadius: lm.maximumRegionRadius)
        let items = decision.ordered.map { GeofenceItem(key: $0.key, regionIDs: $0.regionIDs) }
        let plan = GeofenceReconcilePlanner.plan(items: items, monitored: monitored, limit: decision.itemLimit)

        // 先に外して枠を空けてから登録する。入れ替えが要らなくなったら円も外す
        if !decision.rotationNeeded {
            lm.stopRotationCircle()
            lm.setSignificantChangeMonitoring(false)
        }
        for id in plan.stopRegionIDs {
            if let range = id.range(of: "|wp|") {
                lm.stopMonitoringRoute(memoID: String(id[..<range.lowerBound]))
            } else {
                lm.stopMonitoring(memoID: id)
            }
        }
        for key in plan.stop {
            if sharedByKey[key] != nil {
                lm.stopMonitoring(memoID: key)
            } else if let memo = ownByKey[key] {
                if memo.isRouteTrigger { lm.stopMonitoringRoute(memoID: key) } else { lm.stopMonitoring(memoID: key) }
            }
        }
        let check = reason == .rotation
        for key in plan.start {
            if let s = sharedByKey[key] {
                lm.startMonitoring(region: s.monitoringRegion, checkInitialState: check)
            } else if let memo = ownByKey[key] {
                if memo.isRouteTrigger {
                    lm.startMonitoringRoute(for: memo)
                } else {
                    let region = CLCircularRegion(
                        center: CLLocationCoordinate2D(latitude: memo.latitude, longitude: memo.longitude),
                        radius: memo.radius, identifier: key)
                    region.notifyOnEntry = memo.notifyOnEntry
                    region.notifyOnExit = memo.notifyOnExit
                    lm.startMonitoring(region: region, checkInitialState: check)
                }
            }
        }

        // 入れ替え用の円: 本物の現在地があるときだけ張り直す（円だけが基準のときは、いまの円のまま）。
        // 古い・精度の粗い位置では張らず、取り直してもう 1 回だけやり直す。
        guard decision.rotationNeeded else { return }
        lm.setSignificantChangeMonitoring(true)
        guard let location else { return }
        guard let radius = decision.circleRadius else {
            lm.stopRotationCircle()
            return
        }
        guard NearestRotation.isReliable(location, radius: radius) else {
            if retryOnUnreliable {
                Task { @MainActor in
                    guard await lm.freshLocation(maxAge: 0) != nil else { return }
                    reconcile(memos: memos, sharedMemos: sharedMemos, reason: reason, retryOnUnreliable: false)
                }
            }
            return
        }
        lm.startRotationCircle(center: location.coordinate, radius: radius)
    }
}

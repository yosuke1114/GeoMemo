import Foundation
import CoreLocation

// 20 件を超えても通知できるようにする、近い順の入れ替え（純粋ロジック）。
// iOS が同時に監視できるのは 20 件までなので、受信した依頼を先に、自分のメモは現在地に近いものから登録し、
// 入れ替え用の大きな円（現在地中心・出たら入れ替え）を 1 件使う。副作用は `GeofenceReconciler` / `LocationManager`。

/// 入れ替えの対象 1 件分（メモ 1 件・依頼 1 件）。ルートは経由地ごとに中心を持つ。
nonisolated struct RotationPlace: Equatable, Sendable {
    let key: String
    let regionIDs: [String]
    let centers: [CLLocationCoordinate2D]
    let radius: Double
    let createdAt: Date
    let isReceived: Bool

    static func == (l: RotationPlace, r: RotationPlace) -> Bool {
        l.key == r.key && l.regionIDs == r.regionIDs && l.radius == r.radius
            && l.createdAt == r.createdAt && l.isReceived == r.isReceived
            && l.centers.map(\.latitude) == r.centers.map(\.latitude)
            && l.centers.map(\.longitude) == r.centers.map(\.longitude)
    }
}

/// 入れ替え用の円。端末の中だけに保存する（CloudKit には載せない）。位置の履歴ではなく、最後の 1 件だけ。
nonisolated struct RotationCircle: Equatable, Codable, Sendable {
    var latitude: Double
    var longitude: Double
    var radius: Double
    var rotatedAt: Date
}

nonisolated enum NearestRotation {
    /// 入れ替え用の円の識別子。`isAppRegionIdentifier` には当てはまらない形にしてある。
    static let circleIdentifier = "geomemo.rotation"
    /// 円が使う枠の数。
    static let reservedSlots = 1
    /// 円の半径の下限（m）。小さすぎる円は iOS が正確に扱えない。
    static let minRadius: Double = 200
    /// 次に監視に入る場所までの距離に対する、円の半径の割合（出る前に余裕を持って入れ替えるため）。
    static let radiusFraction: Double = 0.7

    /// 入れ替えが要るか。監視したい領域の合計が上限を超えるとき。
    static func isNeeded(totalRegions: Int, limit: Int = 20) -> Bool { totalRegions > limit }

    /// 項目の登録に使える枠。入れ替えが要るときは、円の分を引く。
    static func itemLimit(totalRegions: Int, limit: Int = 20) -> Int {
        isNeeded(totalRegions: totalRegions, limit: limit) ? limit - reservedSlots : limit
    }

    /// 現在地から場所の縁までの距離（m）。中にいれば 0。ルートは、いちばん近い経由地まで。
    static func edgeDistance(of place: RotationPlace, from location: CLLocation) -> Double {
        let d = place.centers
            .map { location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }
            .min() ?? .greatestFiniteMagnitude
        return max(0, d - place.radius)
    }

    /// 優先順に並べる。受信した依頼が先（入力の順のまま）。自分のメモは現在地から縁までが近い順、
    /// 同じなら作成日の新しい順。現在地が分からないときは作成日の新しい順（以前の並び）。
    static func order(_ places: [RotationPlace], from location: CLLocation?) -> [RotationPlace] {
        let received = places.filter(\.isReceived)
        let own = places.filter { !$0.isReceived }
        guard let location else {
            return received + own.sorted { $0.createdAt > $1.createdAt }
        }
        let keyed = own.map { ($0, edgeDistance(of: $0, from: location)) }
        let sorted = keyed.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.0.createdAt != b.0.createdAt { return a.0.createdAt > b.0.createdAt }
            return a.0.key < b.0.key
        }
        return received + sorted.map(\.0)
    }

    /// `limit` 件の枠に、優先順で収まる項目の key（領域がすべて収まるときだけ選ぶ。`GeofenceReconcilePlanner` と同じ規則）。
    static func selectedKeys(ordered: [RotationPlace], limit: Int) -> Set<String> {
        var budget = limit
        var keys: Set<String> = []
        for place in ordered where !place.regionIDs.isEmpty {
            if place.regionIDs.count <= budget {
                budget -= place.regionIDs.count
                keys.insert(place.key)
            }
        }
        return keys
    }

    /// 入れ替え用の円の半径（m）。外れた項目のうち最も近いものの縁までの距離から決める
    /// （円の中にいる間は、外れた項目の領域に入れない）。外れた項目が無ければ nil（円は要らない）。
    /// `maxRadius` は iOS が監視できる最大の距離（`maximumRegionMonitoringDistance`。負のときは上限なし）。
    static func circleRadius(
        ordered: [RotationPlace], selected: Set<String>, from location: CLLocation, maxRadius: Double
    ) -> Double? {
        let dropped = ordered.filter { !selected.contains($0.key) && !$0.regionIDs.isEmpty }
        guard !dropped.isEmpty else { return nil }
        let nearest = dropped.map { edgeDistance(of: $0, from: location) }.min() ?? 0
        var radius = max(minRadius, nearest * radiusFraction)
        if maxRadius > 0 { radius = min(radius, maxRadius) }
        return radius
    }

    /// 現在地が円の外か（円が無いときも入れ替える）。有効半径の判定は iOS に任せ、ここは中心からの距離だけを見る。
    static func isOutside(_ circle: RotationCircle?, location: CLLocation) -> Bool {
        guard let circle else { return true }
        let center = CLLocation(latitude: circle.latitude, longitude: circle.longitude)
        return location.distance(from: center) > circle.radius
    }

    /// 入れ替えのあとの「内側にいた」判定を進入として扱うか。登録直後の状態確認（`requestState`）の結果を渡す。
    /// すでに内側として通知済み（進入イベントや前回の確認で扱った）なら、重複させない。
    static func shouldTreatAsEntry(isInside: Bool, alreadyInside: Bool) -> Bool {
        isInside && !alreadyInside
    }
}

/// 入れ替えのときに領域の内側として扱った識別子の控え（重複通知の防止）。
/// 進入イベントで追加し、退出・監視から外れたときに消す。端末の中だけに保存する。
nonisolated struct InsideLedger: Equatable, Codable, Sendable {
    private(set) var ids: Set<String> = []
    func contains(_ id: String) -> Bool { ids.contains(id) }
    mutating func insert(_ id: String) { ids.insert(id) }
    mutating func remove(_ id: String) { ids.remove(id) }
    /// 監視中でなくなったものを消す。
    mutating func retain(only monitored: Set<String>) { ids.formIntersection(monitored) }
}

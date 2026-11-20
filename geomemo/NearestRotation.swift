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
    /// 入れ替えで外さない（進み具合が 1 以上のルート。外すと進み具合が 0 に戻る）。
    var isPinned: Bool = false

    static func == (l: RotationPlace, r: RotationPlace) -> Bool {
        l.key == r.key && l.regionIDs == r.regionIDs && l.radius == r.radius
            && l.createdAt == r.createdAt && l.isReceived == r.isReceived && l.isPinned == r.isPinned
            && l.centers.map(\.latitude) == r.centers.map(\.latitude)
            && l.centers.map(\.longitude) == r.centers.map(\.longitude)
    }
}

/// 入れ替え用の円。保存はしない（登録済みの領域 `geomemo.rotation` の中心と半径をそのまま読む。
/// アプリ側には位置を書き出さないので、バックアップにも最後の位置は残らない）。
nonisolated struct RotationCircle: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var radius: Double

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

/// `NearestRotation.decide` の結果。
nonisolated struct RotationDecision: Equatable, Sendable {
    var ordered: [RotationPlace]
    /// 項目の登録に使える枠（円を使うときは 1 引く）。
    var itemLimit: Int
    var rotationNeeded: Bool
    var selected: Set<String>
    /// 円の半径。外れた項目が無い・基準の位置が無いときは nil。
    var circleRadius: Double?
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

    /// 入れ替えが要るか。監視したい領域の合計が上限を超え、かつ受信した依頼で枠が埋まっていないとき
    /// （受信した依頼だけで 20 件以上なら、自分のメモは入れず、円も張らない）。
    static func isNeeded(totalRegions: Int, receivedRegions: Int = 0, limit: Int = 20) -> Bool {
        totalRegions > limit && receivedRegions < limit
    }

    /// 項目の登録に使える枠。入れ替えが要るときは、円の分を引く。
    static func itemLimit(totalRegions: Int, receivedRegions: Int = 0, limit: Int = 20) -> Int {
        isNeeded(totalRegions: totalRegions, receivedRegions: receivedRegions, limit: limit) ? limit - reservedSlots : limit
    }

    /// 円の登録に使える位置か。古い・精度が半径に対して粗い位置では、円を張り直さず取り直す。
    static func isReliable(_ location: CLLocation, radius: Double, now: Date = Date(), maxAge: TimeInterval = 120) -> Bool {
        guard location.horizontalAccuracy >= 0 else { return false }
        return now.timeIntervalSince(location.timestamp) <= maxAge && location.horizontalAccuracy <= radius * 0.5
    }

    /// 現在地から場所の縁までの距離（m）。中にいれば 0。ルートは、いちばん近い経由地まで。
    static func edgeDistance(of place: RotationPlace, from location: CLLocation) -> Double {
        let d = place.centers
            .map { location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }
            .min() ?? .greatestFiniteMagnitude
        return max(0, d - place.radius)
    }

    /// 優先順に並べる。受信した依頼が先（入力の順のまま）、次に外せない項目（進み具合のあるルート）、
    /// 残りの自分のメモは基準の位置から縁までが近い順（同じなら作成日の新しい順）。
    /// 基準の位置が無いとき（現在地も円も分からない）は、いま監視している項目を先に、残りは作成日の新しい順
    /// （既存の並びを変えず、増減した分だけを反映する）。
    static func order(_ places: [RotationPlace], from location: CLLocation?, monitoredKeys: Set<String> = []) -> [RotationPlace] {
        func rank(_ group: [RotationPlace]) -> [RotationPlace] {
            guard let location else {
                return group.sorted { a, b in
                    let am = monitoredKeys.contains(a.key), bm = monitoredKeys.contains(b.key)
                    if am != bm { return am }
                    if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
                    return a.key < b.key
                }
            }
            let keyed = group.map { ($0, edgeDistance(of: $0, from: location)) }
            return keyed.sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.0.createdAt != b.0.createdAt { return a.0.createdAt > b.0.createdAt }
                return a.0.key < b.0.key
            }.map(\.0)
        }
        let received = places.filter(\.isReceived)
        let pinned = places.filter { !$0.isReceived && $0.isPinned }
        let rest = places.filter { !$0.isReceived && !$0.isPinned }
        return received + rank(pinned) + rank(rest)
    }

    /// `limit` 件の枠に、優先順で収まる項目の key（領域がすべて収まるときだけ選ぶ。`GeofenceReconcilePlanner` と同じ規則）。
    /// 他の機能の領域が枠を使っているときは、その数を引いた枠を渡す（planner は同じように数える）。
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
    /// 限界: 外れた項目のうち最寄りが近い（円の下限 200 m より近い）密集地では、円が外れた項目の領域に届く。
    /// その場合は円を出てから入れ替わるまでの間（数百 m〜数分）、外れた項目の進入を取りこぼしうる。
    /// 入れ替えのとき `requestState` で内側かを確かめるので、入れ替わった時点で中にいれば通知される。
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

    /// 判断をまとめた純粋関数（並び・枠・円の大きさ）。`foreignRegions` は他の機能の領域の数。
    static func decide(
        places: [RotationPlace], anchor: CLLocation?, monitoredKeys: Set<String>,
        foreignRegions: Int = 0, maxRadius: Double, limit: Int = 20
    ) -> RotationDecision {
        let total = places.reduce(0) { $0 + $1.regionIDs.count }
        let received = places.filter(\.isReceived).reduce(0) { $0 + $1.regionIDs.count }
        let needed = isNeeded(totalRegions: total, receivedRegions: received, limit: limit)
        let itemLimit = itemLimit(totalRegions: total, receivedRegions: received, limit: limit)
        let ordered = order(places, from: anchor, monitoredKeys: monitoredKeys)
        let selected = selectedKeys(ordered: ordered, limit: max(0, itemLimit - foreignRegions))
        var radius: Double?
        if needed, let anchor {
            radius = circleRadius(ordered: ordered, selected: selected, from: anchor, maxRadius: maxRadius)
        }
        return RotationDecision(ordered: ordered, itemLimit: itemLimit, rotationNeeded: needed, selected: selected, circleRadius: radius)
    }

    /// 現在地が円の外か（円が無いときも入れ替える）。有効半径の判定は iOS に任せ、ここは中心からの距離だけを見る。
    static func isOutside(_ circle: RotationCircle?, location: CLLocation) -> Bool {
        guard let circle else { return true }
        return location.distance(from: circle.location) > circle.radius
    }

    /// 入れ替えのあとの「内側にいた」判定を進入として扱うか。登録直後の状態確認（`requestState`）の結果を渡す。
    /// すでに内側として通知済み（進入イベントや前回の確認で扱った）なら、重複させない。
    static func shouldTreatAsEntry(isInside: Bool, alreadyInside: Bool) -> Bool {
        isInside && !alreadyInside
    }
}

/// 入れ替えのときに領域の内側として扱った識別子の控え（重複通知の防止）。
/// 進入イベントで追加し、退出・監視から外れたとき・許可が下がったとき・全停止で消す。端末の中だけに保存する。
nonisolated struct InsideLedger: Equatable, Codable, Sendable {
    private(set) var ids: Set<String> = []
    func contains(_ id: String) -> Bool { ids.contains(id) }
    mutating func insert(_ id: String) { ids.insert(id) }
    mutating func remove(_ id: String) { ids.remove(id) }
}

/// 状態確認（`requestState`）で進入として扱った直後の、同じ領域の進入イベントを捨てるための記録（二重通知の防止）。
nonisolated struct RecentEntries: Equatable, Sendable {
    /// 状態確認と進入イベントの順序は決まっていないので、この時間内の 2 回目は同じ進入として扱う。
    static let window: TimeInterval = 300
    private(set) var times: [String: Date] = [:]
    mutating func record(_ id: String, at date: Date) { times[id] = date }
    mutating func forget(_ id: String) { times[id] = nil }
    func isRecent(_ id: String, now: Date) -> Bool {
        guard let t = times[id] else { return false }
        return now.timeIntervalSince(t) < Self.window
    }
}

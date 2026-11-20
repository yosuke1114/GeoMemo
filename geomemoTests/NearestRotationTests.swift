import Testing
import Foundation
import CoreLocation
@testable import geomemo

// 近い順の入れ替え（純粋ロジック）のテスト。

private let tokyo = CLLocation(latitude: 35.6812, longitude: 139.7671)

/// 東京駅から真東に `meters` m 離れた点（緯度 35.68 付近で経度 1 度 ≒ 90.6 km）。
private func east(_ meters: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671 + meters / 90_600)
}

private func place(
    _ key: String, at meters: Double = 0, radius: Double = 100, age: TimeInterval = 0,
    received: Bool = false, waypoints: [Double]? = nil
) -> RotationPlace {
    let centers = (waypoints ?? [meters]).map(east)
    let ids = waypoints == nil ? [key] : (0..<centers.count).map { "\(key)|wp|\($0)" }
    return RotationPlace(key: key, regionIDs: ids, centers: centers, radius: radius,
                         createdAt: Date(timeIntervalSince1970: 1_000_000 - age), isReceived: received)
}

@Suite("NearestRotation")
struct NearestRotationTests {
    @Test("並び: 受信した依頼が先、自分のメモは現在地に近い順（古くても近ければ先）")
    func order() {
        let places = [place("far", at: 5_000), place("near-old", at: 300, age: 9_000), place("mid", at: 1_000),
                      place("req", at: 50_000, received: true)]
        let keys = NearestRotation.order(places, from: tokyo).map(\.key)
        #expect(keys == ["req", "near-old", "mid", "far"])
    }

    @Test("並び: 縁までの距離で比べる（半径が大きければ、中心が遠くても近い）。中にいれば 0")
    func edgeDistance() {
        let big = place("big", at: 2_000, radius: 1_900)
        let small = place("small", at: 500, radius: 100)
        #expect(NearestRotation.order([small, big], from: tokyo).map(\.key) == ["big", "small"])
        #expect(NearestRotation.edgeDistance(of: place("in", at: 50, radius: 100), from: tokyo) == 0)
        let d = NearestRotation.edgeDistance(of: small, from: tokyo)
        #expect(abs(d - 400) < 5)
    }

    @Test("並び: ルートはいちばん近い経由地までの距離")
    func routeDistance() {
        let route = place("route", waypoints: [8_000, 200, 4_000])
        let other = place("other", at: 1_000)
        #expect(NearestRotation.order([other, route], from: tokyo).map(\.key) == ["route", "other"])
    }

    @Test("並び: 同じ距離なら作成日の新しい順。現在地が無ければ作成日の新しい順（受信した依頼は先）")
    func tiesAndNoLocation() {
        let a = place("a", at: 500, age: 100), b = place("b", at: 500, age: 10)
        #expect(NearestRotation.order([a, b], from: tokyo).map(\.key) == ["b", "a"])
        let far = place("far", at: 9_000, age: 1), near = place("near", at: 10, age: 500)
        let req = place("req", received: true)
        #expect(NearestRotation.order([near, far, req], from: nil).map(\.key) == ["req", "far", "near"])
    }

    @Test("入れ替えが要るのは領域が 20 件を超えるときだけ。そのとき項目の枠は 19 件")
    func needed() {
        #expect(!NearestRotation.isNeeded(totalRegions: 20))
        #expect(NearestRotation.isNeeded(totalRegions: 21))
        #expect(NearestRotation.itemLimit(totalRegions: 20) == 20)
        #expect(NearestRotation.itemLimit(totalRegions: 21) == 19)
    }

    @Test("選ぶ項目: 領域がすべて収まるときだけ（収まらないルートは飛ばして後ろの小さい項目を入れる）")
    func selection() {
        let ordered = [place("a", at: 1), place("r", waypoints: [10, 20, 30]), place("b", at: 100)]
        #expect(NearestRotation.selectedKeys(ordered: ordered, limit: 4) == ["a", "r"])
        #expect(NearestRotation.selectedKeys(ordered: ordered, limit: 3) == ["a", "b"])
    }

    @Test("円の半径: 外れた項目のうち最も近いものの縁までの 7 割。下限・上限がある。外れが無ければ円は要らない")
    func circleRadius() {
        let ordered = [place("a", at: 100), place("b", at: 500), place("c", at: 6_100), place("d", at: 9_100)]
        let selected: Set<String> = ["a", "b"]
        let r = NearestRotation.circleRadius(ordered: ordered, selected: selected, from: tokyo, maxRadius: -1)!
        // c の縁まで ≒ 6000 m → 4200 m
        #expect(abs(r - 4_200) < 60)
        // iOS の最大距離を超えない
        #expect(NearestRotation.circleRadius(ordered: ordered, selected: selected, from: tokyo, maxRadius: 3_000) == 3_000)
        // 外れた項目がすぐ近くにあっても、下限より小さくしない
        let tight = [place("a", at: 100), place("b", at: 150)]
        #expect(NearestRotation.circleRadius(ordered: tight, selected: ["a"], from: tokyo, maxRadius: -1) == NearestRotation.minRadius)
        #expect(NearestRotation.circleRadius(ordered: ordered, selected: ["a", "b", "c", "d"], from: tokyo, maxRadius: -1) == nil)
    }

    @Test("円の外か: 円が無ければ入れ替える。半径の内側なら入れ替えない")
    func outside() {
        #expect(NearestRotation.isOutside(nil, location: tokyo))
        let circle = RotationCircle(latitude: tokyo.coordinate.latitude, longitude: tokyo.coordinate.longitude,
                                    radius: 1_000, rotatedAt: Date())
        let inside = CLLocation(latitude: east(900).latitude, longitude: east(900).longitude)
        let out = CLLocation(latitude: east(1_100).latitude, longitude: east(1_100).longitude)
        #expect(!NearestRotation.isOutside(circle, location: inside))
        #expect(NearestRotation.isOutside(circle, location: out))
    }

    @Test("登録直後に内側だった: 通知済みでなければ進入として扱い、済みなら重複させない")
    func entryPolicy() {
        #expect(NearestRotation.shouldTreatAsEntry(isInside: true, alreadyInside: false))
        #expect(!NearestRotation.shouldTreatAsEntry(isInside: true, alreadyInside: true))
        #expect(!NearestRotation.shouldTreatAsEntry(isInside: false, alreadyInside: false))
    }

    @Test("内側の控え: 追加・削除・監視中のものだけに絞る。保存・復元できる")
    func ledger() throws {
        var l = InsideLedger()
        l.insert("a"); l.insert("b"); l.insert("c")
        l.remove("a")
        l.retain(only: ["b", "x"])
        #expect(l.contains("b") && !l.contains("a") && !l.contains("c"))
        let restored = try JSONDecoder().decode(InsideLedger.self, from: JSONEncoder().encode(l))
        #expect(restored == l)
    }

    @Test("入れ替え用の円の識別子は、このアプリのメモ・依頼・経由地の形式ではない")
    func circleIdentifier() {
        #expect(!isAppRegionIdentifier(NearestRotation.circleIdentifier))
    }

    @Test("どのスレッドからでも呼べる")
    func offMain() async {
        let places = [place("a", at: 1_000), place("b", at: 500)]
        let keys = await Task.detached {
            NearestRotation.order(places, from: CLLocation(latitude: 35.6812, longitude: 139.7671)).map(\.key)
        }.value
        #expect(keys == ["b", "a"])
    }

    // MARK: 入れ替えの通し（25 件のメモを持って東へ移動する）

    @Test("25 件のメモ: 近い 19 件を監視し、移動すると遠い・近いが入れ替わる。差分は入れ替わった分だけ")
    func movingRotation() {
        // 東へ 1 km 間隔で 25 件（半径 100 m）
        let places = (0..<25).map { place("m\($0)", at: Double($0) * 1_000, age: Double($0)) }
        func step(from location: CLLocation, monitored: Set<String>) -> (selected: Set<String>, plan: GeofenceReconcilePlanner.Plan) {
            let ordered = NearestRotation.order(places, from: location)
            let limit = NearestRotation.itemLimit(totalRegions: places.count)
            let items = ordered.map { GeofenceItem(key: $0.key, regionIDs: $0.regionIDs) }
            // 領域の識別子は key と同じ。UUID ではないので、消した扱いにならないよう「既知」にしてある
            return (NearestRotation.selectedKeys(ordered: ordered, limit: limit),
                    GeofenceReconcilePlanner.plan(items: items, monitored: monitored, limit: limit))
        }
        let start = step(from: tokyo, monitored: [])
        #expect(start.selected.count == 19)
        #expect(start.selected.contains("m0") && start.selected.contains("m18") && !start.selected.contains("m19"))

        // 12 km 東へ移動
        let moved = CLLocation(latitude: east(12_000).latitude, longitude: east(12_000).longitude)
        let next = step(from: moved, monitored: start.selected)
        #expect(next.selected.contains("m12") && next.selected.contains("m3") && next.selected.contains("m21"))
        #expect(!next.selected.contains("m0") && !next.selected.contains("m2") && !next.selected.contains("m22"))
        // 入れ替わった分だけが動く（残るものは触らない）
        #expect(Set(next.plan.stop) == start.selected.subtracting(next.selected))
        #expect(Set(next.plan.start) == next.selected.subtracting(start.selected))
        #expect(Set(next.plan.start).isDisjoint(with: start.selected))
    }
}

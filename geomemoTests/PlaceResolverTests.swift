import Testing
import Foundation
@testable import geomemo

@Suite("PlaceResolver")
struct PlaceResolverTests {
    private func place(_ name: String, sub: String = "", icon: String = "mappin.fill",
                       lat: Double = 35.68, lon: Double = 139.76) -> PlaceCandidate {
        PlaceCandidate(id: UUID(), name: name, subtitle: sub, latitude: lat, longitude: lon, iconName: icon)
    }

    @Test("正規化: 全角・半角、大文字小文字、カタカナ、空白と記号を無視する")
    func normalize() {
        #expect(PlaceResolver.normalize("ＣＡＦＥ  Ｍｏｋａ") == "cafemoka")
        #expect(PlaceResolver.normalize("ジム") == PlaceResolver.normalize("じむ"))
        #expect(PlaceResolver.normalize(" 駅・前 ") == "駅前")
        #expect(PlaceResolver.normalize("") == "")
    }

    @Test("名前が完全に一致すれば 1 件に決まる")
    func exactName() {
        let home = place("自宅"), work = place("職場")
        #expect(PlaceResolver.resolve("自宅", in: [home, work]) == .resolved(home))
    }

    @Test("アイコン由来の別名で引ける（名前が「実家」でも家のアイコンなら「自宅」で当たる）")
    func iconAlias() {
        let home = place("実家", icon: "house.fill")
        #expect(PlaceResolver.resolve("自宅", in: [home, place("駅")]) == .resolved(home))
        #expect(PlaceResolver.resolve("home", in: [home]) == .resolved(home))
    }

    @Test("名前の完全一致は別名より強い")
    func exactBeatsAlias() {
        let named = place("自宅", icon: "mappin.fill")
        let aliased = place("実家", icon: "house.fill")
        #expect(PlaceResolver.resolve("自宅", in: [aliased, named]) == .resolved(named))
    }

    @Test("同じ強さで複数当たれば ambiguous（名前順）")
    func ambiguous() {
        let a = place("スーパーB"), b = place("スーパーA")
        #expect(PlaceResolver.resolve("スーパー", in: [a, b]) == .ambiguous([b, a]))
    }

    @Test("検索語が名前を含む言い方も拾う。1 文字の名前では誤って当てない")
    func longerPhrase() {
        let home = place("自宅")
        #expect(PlaceResolver.resolve("自宅の近く", in: [home]) == .resolved(home))
        #expect(PlaceResolver.resolve("駅前の本屋", in: [place("駅")]) == .notFound)
    }

    @Test("住所でも引ける。無ければ notFound、空の検索語も notFound")
    func subtitleAndNotFound() {
        let p = place("ジム", sub: "渋谷区")
        #expect(PlaceResolver.resolve("渋谷", in: [p]) == .resolved(p))
        #expect(PlaceResolver.resolve("京都", in: [p]) == .notFound)
        #expect(PlaceResolver.resolve("  ", in: [p]) == .notFound)
        #expect(PlaceResolver.resolve("自宅", in: []) == .notFound)
    }

    @Test("matching は強い段から重複なしで並べる")
    func matchingOrder() {
        let exact = place("カフェ"), prefix = place("カフェ モカ"), alias = place("コーヒー店", icon: "cup.and.saucer.fill")
        let result = PlaceResolver.matching("カフェ", in: [prefix, alias, exact])
        #expect(result.map(\.id) == [exact.id, alias.id, prefix.id])
    }

    @Test("どのスレッドからでも呼べる")
    func offMain() async {
        let p = place("自宅")
        let r = await Task.detached { PlaceResolver.resolve("自宅", in: [p]) }.value
        #expect(r == .resolved(p))
    }
}

@Suite("PlaceMemoDraft")
struct PlaceMemoDraftTests {
    private func place(lat: Double = 35.68, lon: Double = 139.76) -> PlaceCandidate {
        PlaceCandidate(id: UUID(), name: "自宅", subtitle: "", latitude: lat, longitude: lon, iconName: "house.fill")
    }

    @Test("題を整え、場所の名前・座標・既定の範囲を引き継ぐ")
    func makes() {
        let d = PlaceMemoDraft.make(title: "  ゴミ出し ", note: "朝", place: place())
        #expect(d == PlaceMemoDraft(title: "ゴミ出し", note: "朝", locationName: "自宅",
                                    latitude: 35.68, longitude: 139.76, radius: 100))
    }

    @Test("題が空、座標が壊れている場合は作らない")
    func rejects() {
        #expect(PlaceMemoDraft.make(title: "   ", note: "", place: place()) == nil)
        #expect(PlaceMemoDraft.make(title: "a", note: "", place: place(lat: 0, lon: 0)) == nil)
        #expect(PlaceMemoDraft.make(title: "a", note: "", place: place(lat: .nan)) == nil)
        #expect(PlaceMemoDraft.make(title: "a", note: "", place: place(lon: 200)) == nil)
    }
}

@Suite("FavoritePlaceEntity")
struct FavoritePlaceEntityTests {
    @Test("お気に入りの場所のモデルから値型を経て、元の値に戻せる")
    func roundTrip() {
        let model = FavoritePlace(name: "職場", subtitle: "丸の内", latitude: 35.68, longitude: 139.76, iconName: "building.2.fill")
        let candidate = PlaceCandidate(model)
        let entity = FavoritePlaceEntity(from: candidate)
        #expect(entity.id == model.id)
        #expect(entity.candidate == candidate)
        #expect(entity.name == "職場" && entity.iconName == "building.2.fill")
    }
}

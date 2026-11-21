import Foundation

// 「場所の名前」から保存済みの場所を引く、純粋なロジック。
// App Intents（今回のショートカット）と、のちの文章入力（L-4）の両方から使う。
// SwiftData・位置情報・UI には依存しない（値型だけ）ので、どのスレッドからでも呼べる。

/// 場所の候補 1 件。お気に入りの場所などから作る。
nonisolated struct PlaceCandidate: Equatable, Sendable, Identifiable {
    /// 元のデータでの ID（お気に入りの場所なら UUID）。
    let id: UUID
    let name: String
    /// 住所・エリア名。
    let subtitle: String
    let latitude: Double
    let longitude: Double
    /// SF Symbol 名。「自宅」「職場」などの別名の手がかりに使う。
    let iconName: String
}

nonisolated enum PlaceResolution: Equatable, Sendable {
    /// 1 件に決まった。
    case resolved(PlaceCandidate)
    /// 同じ強さで複数の候補が当てはまった（呼び出し側が聞き返す・選ばせる）。
    case ambiguous([PlaceCandidate])
    case notFound
}

nonisolated enum PlaceResolver {
    /// 比較用に揃える。全角・半角、大文字・小文字、カタカナ・ひらがな、空白と記号の違いを無視する。
    nonisolated static func normalize(_ text: String) -> String {
        let folded = text
            .precomposedStringWithCompatibilityMapping   // 全角英数・半角カナを正規化（NFKC）
            .lowercased()
        // カタカナ → ひらがな
        let hira = folded.applyingTransform(.hiraganaToKatakana, reverse: true) ?? folded
        let drop = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return String(String.UnicodeScalarView(hira.unicodeScalars.filter { !drop.contains($0) }))
    }

    /// アイコンから分かる呼び名。名前を付けていなくても「自宅」「職場」で引けるようにする。
    nonisolated static func aliases(forIcon iconName: String) -> [String] {
        switch iconName {
        case "house.fill":           ["自宅", "家", "うち", "home", "house"]
        case "building.2.fill":      ["職場", "会社", "仕事場", "勤務先", "work", "office"]
        case "train.side.front.car": ["駅", "station"]
        case "dumbbell.fill":        ["ジム", "gym"]
        case "cup.and.saucer.fill":  ["カフェ", "cafe", "coffee"]
        case "cart.fill":            ["スーパー", "買い物", "shop"]
        case "book.fill":            ["本屋", "書店", "bookstore"]
        default:                     []
        }
    }

    /// 段ごとの候補（空の段も残す。添字が強さ: 0=完全一致 / 1=別名 / 2=前方一致 / 3=含む / 4=住所）。
    nonisolated static func rankedTiers(for query: String, in candidates: [PlaceCandidate]) -> [[PlaceCandidate]] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        let items = candidates.map { ($0, normalize($0.name), normalize($0.subtitle)) }

        func tier(_ predicate: (PlaceCandidate, String, String) -> Bool) -> [PlaceCandidate] {
            items.filter { predicate($0.0, $0.1, $0.2) }
                .map(\.0)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return [
            tier { _, name, _ in name == q },
            tier { c, _, _ in aliases(forIcon: c.iconName).contains { normalize($0) == q } },
            tier { _, name, _ in !name.isEmpty && name.hasPrefix(q) },
            // 「自宅の近く」のように、名前を含む長い言い方も拾う。1 文字の名前では誤って当たるので除く。
            tier { _, name, _ in name.contains(q) || (name.count >= 2 && q.contains(name)) },
            tier { _, _, sub in !sub.isEmpty && sub.contains(q) },
        ]
    }

    /// 検索語に当てはまる候補を、強い順の段ごとに返す。段の中は名前順。
    /// 1 段目: 名前が完全に一致 / 2 段目: アイコン由来の別名が一致 /
    /// 3 段目: 名前が検索語で始まる / 4 段目: 名前が検索語を含む・検索語が名前を含む / 5 段目: 住所に含まれる
    nonisolated static func tiers(for query: String, in candidates: [PlaceCandidate]) -> [[PlaceCandidate]] {
        rankedTiers(for: query, in: candidates).filter { !$0.isEmpty }
    }

    /// 強い段（完全一致・別名・前方一致）に当たった候補。含む・住所だけの弱い一致は入れない。
    nonisolated static func strongMatches(for query: String, in candidates: [PlaceCandidate]) -> [PlaceCandidate] {
        dedupe(rankedTiers(for: query, in: candidates).prefix(3).flatMap { $0 })
    }

    /// 弱い段（含む・住所）だけに当たった候補（強い段に当たったものは除く）。
    nonisolated static func weakMatches(for query: String, in candidates: [PlaceCandidate]) -> [PlaceCandidate] {
        let strong = Set(strongMatches(for: query, in: candidates).map(\.id))
        return dedupe(rankedTiers(for: query, in: candidates).dropFirst(3).flatMap { $0 }).filter { !strong.contains($0.id) }
    }

    nonisolated private static func dedupe(_ places: [PlaceCandidate]) -> [PlaceCandidate] {
        var seen = Set<UUID>()
        return places.filter { seen.insert($0.id).inserted }
    }

    /// 1 件に決める。最も強い段に 1 件ならその場所、複数なら聞き返し用の一覧、無ければ見つからない。
    nonisolated static func resolve(_ query: String, in candidates: [PlaceCandidate]) -> PlaceResolution {
        guard let best = tiers(for: query, in: candidates).first else { return .notFound }
        return best.count == 1 ? .resolved(best[0]) : .ambiguous(best)
    }

    /// 候補の絞り込み（ショートカットの検索欄・Siri の候補用）。強い段から順に、重複なしでつなぐ。
    nonisolated static func matching(_ query: String, in candidates: [PlaceCandidate]) -> [PlaceCandidate] {
        var seen = Set<UUID>()
        return tiers(for: query, in: candidates).flatMap { $0 }.filter { seen.insert($0.id).inserted }
    }
}

/// 場所を指定して作るメモの中身。保存前の検査と既定値をここにまとめる。
nonisolated struct PlaceMemoDraft: Equatable, Sendable {
    /// 範囲の既定値（m）。画面の追加と同じ 100m。
    nonisolated static let defaultRadius: Double = 100

    let title: String
    let note: String
    let locationName: String
    let latitude: Double
    let longitude: Double
    let radius: Double

    /// 題が空（空白だけ）なら nil。座標が範囲外・非数・(0, 0) のときも nil（壊れた保存データでゴーストメモを作らない）。
    nonisolated static func make(title: String, note: String, place: PlaceCandidate,
                                 radius: Double = defaultRadius) -> PlaceMemoDraft? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard place.latitude.isFinite, place.longitude.isFinite,
              (-90...90).contains(place.latitude), (-180...180).contains(place.longitude),
              !(place.latitude == 0 && place.longitude == 0) else { return nil }
        return PlaceMemoDraft(title: trimmed, note: note, locationName: place.name,
                              latitude: place.latitude, longitude: place.longitude, radius: radius)
    }
}

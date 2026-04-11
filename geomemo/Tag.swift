import Foundation

// MARK: - Limits

enum GeoMemoLimits {
    static let maxCustomTags = 5        // Free tier
    static let maxCustomTagLength = 15
    // static let maxCustomTagsPro = 20 // Pro tier（将来）
}

// MARK: - PresetTag

/// 数値IDで管理（表示名はi18n経由）
enum PresetTag: Int, CaseIterable, Codable, Identifiable {
    case work       = 1
    case food       = 2
    case shopping   = 3
    case transit    = 4
    case home       = 5
    case medical    = 6
    case school     = 7
    case leisure    = 8
    case important  = 9
    case memo       = 10

    var id: Int { rawValue }

    var localizedName: String {
        switch self {
        case .work:      return String(localized: "tag.work",      defaultValue: "仕事")
        case .food:      return String(localized: "tag.food",      defaultValue: "食事")
        case .shopping:  return String(localized: "tag.shopping",  defaultValue: "買い物")
        case .transit:   return String(localized: "tag.transit",   defaultValue: "移動")
        case .home:      return String(localized: "tag.home",      defaultValue: "自宅")
        case .medical:   return String(localized: "tag.medical",   defaultValue: "医療")
        case .school:    return String(localized: "tag.school",    defaultValue: "学校")
        case .leisure:   return String(localized: "tag.leisure",   defaultValue: "余暇")
        case .important: return String(localized: "tag.important", defaultValue: "重要")
        case .memo:      return String(localized: "tag.memo",      defaultValue: "メモ")
        }
    }

    var iconName: String {
        switch self {
        case .work:      return "ph-briefcase-bold"
        case .food:      return "ph-fork-knife-bold"
        case .shopping:  return "ph-shopping-bag-bold"
        case .transit:   return "ph-train-bold"
        case .home:      return "ph-house-bold"
        case .medical:   return "ph-first-aid-kit-bold"
        case .school:    return "ph-graduation-cap-bold"
        case .leisure:   return "ph-confetti-bold"
        case .important: return "ph-warning-bold"
        case .memo:      return "ph-note-bold"
        }
    }

    /// キーワードマッチング辞書（日英両対応、タイトル・場所名・ノートに対して照合）
    var keywords: [String] {
        switch self {
        case .work:
            return ["会社", "オフィス", "仕事", "ミーティング", "会議", "打合", "打ち合わせ",
                    "職場", "勤務", "取引先", "出社", "business", "office", "work", "meeting"]
        case .food:
            return ["レストラン", "食堂", "ランチ", "ディナー", "食事", "カフェ", "喫茶",
                    "居酒屋", "ラーメン", "寿司", "焼肉", "定食", "弁当", "飲食",
                    "restaurant", "cafe", "lunch", "dinner", "food", "eat"]
        case .shopping:
            return ["スーパー", "コンビニ", "ドラッグストア", "薬局", "百貨店", "ショッピング",
                    "買い物", "買い", "購入", "通販", "ドン・キホーテ", "イオン",
                    "supermarket", "shop", "store", "buy", "purchase", "mall"]
        case .transit:
            return ["駅", "バス", "空港", "電車", "地下鉄", "乗換", "乗り換え", "出発",
                    "到着", "新幹線", "ターミナル", "停留所",
                    "station", "airport", "bus", "train", "subway", "transit", "transfer"]
        case .home:
            return ["自宅", "家", "帰宅", "帰り", "マンション", "アパート", "実家",
                    "自分の家", "住所",
                    "home", "house", "apartment", "residence", "return"]
        case .medical:
            return ["病院", "クリニック", "医院", "診療所", "薬局", "調剤", "医療",
                    "健診", "検診", "歯科", "歯医者", "処方",
                    "hospital", "clinic", "doctor", "pharmacy", "medical", "health"]
        case .school:
            return ["学校", "大学", "高校", "中学", "小学校", "塾", "予備校", "授業",
                    "講義", "キャンパス", "図書館",
                    "school", "university", "college", "campus", "class", "study"]
        case .leisure:
            return ["公園", "映画", "ショー", "コンサート", "ライブ", "遊園地", "観光",
                    "旅行", "休暇", "休日", "趣味", "スポーツ", "ジム",
                    "park", "movie", "concert", "travel", "leisure", "hobby", "gym"]
        case .important:
            return ["重要", "緊急", "必ず", "忘れずに", "期限", "締切", "要確認",
                    "注意", "必須", "絶対",
                    "important", "urgent", "deadline", "critical", "must", "remember"]
        case .memo:
            return ["メモ", "覚書", "備忘録", "確認", "チェック", "リスト",
                    "note", "reminder", "check", "list", "memo"]
        }
    }
}

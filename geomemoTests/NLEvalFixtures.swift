import Foundation
@testable import geomemo

// 評価用の例文と期待値（日本語 20 件・英語 10 件）。docs/natural-language-memo-eval.md と同じ内容。
// 実機の端末内モデルで評価するときの正解表。単体テストでは、この期待値が検査のロジックを通ることだけを確かめる（モデルは呼ばない）。

struct NLEvalCase: Sendable {
    let id: String
    let language: String
    let text: String
    /// 題に含まれてほしい語。空なら検査しない。
    let titleKeyword: String
    /// 場所の語（モデルが placeQuery に入れてほしい語）。空なら場所なし。
    let placeQuery: String
    /// "fav": お気に入りの場所で引く / "search": 地図で探す / "none": 場所なし
    let placeKind: String
    /// "arrive" / "leave" / "both" / "unspecified"
    let trigger: String
    /// "HH:mm-HH:mm"。無ければ nil。
    let window: String?
    /// 曜日の語（カンマ区切り）。無ければ空。
    let days: String
    /// 期限の期待（人が見る説明）。無ければ nil。
    let deadlineRule: String?
    let note: String
}

enum NLEvalFixtures {
    static let cases: [NLEvalCase] = [
        NLEvalCase(id: "ja01", language: "ja", text: "駅に着いたら牛乳を買う", titleKeyword: "牛乳", placeQuery: "駅", placeKind: "fav", trigger: "arrive", window: nil, days: "", deadlineRule: nil, note: ""),
        NLEvalCase(id: "ja02", language: "ja", text: "平日の夕方、駅前のドラッグストアに寄ったら洗剤", titleKeyword: "洗剤", placeQuery: "ドラッグストア", placeKind: "search", trigger: "arrive", window: "16:00-19:00", days: "weekdays", deadlineRule: nil, note: "夕方は 16〜19 時を期待"),
        NLEvalCase(id: "ja03", language: "ja", text: "自宅を出るときに鍵とマスクを持つ", titleKeyword: "鍵", placeQuery: "自宅", placeKind: "fav", trigger: "leave", window: nil, days: "", deadlineRule: nil, note: ""),
        NLEvalCase(id: "ja04", language: "ja", text: "職場に着いたらA社に電話", titleKeyword: "電話", placeQuery: "職場", placeKind: "fav", trigger: "arrive", window: nil, days: "", deadlineRule: nil, note: ""),
        NLEvalCase(id: "ja05", language: "ja", text: "朝、ジムに着いたらプロテインを飲む", titleKeyword: "プロテイン", placeQuery: "ジム", placeKind: "fav", trigger: "arrive", window: "06:00-10:00", days: "", deadlineRule: nil, note: ""),
        NLEvalCase(id: "ja06", language: "ja", text: "土日にスーパーに寄ったら卵を買う", titleKeyword: "卵", placeQuery: "スーパー", placeKind: "search", trigger: "arrive", window: nil, days: "weekends", deadlineRule: nil, note: ""),
        NLEvalCase(id: "ja07", language: "ja", text: "今週の金曜までに、郵便局に着いたら荷物を出す", titleKeyword: "荷物", placeQuery: "郵便局", placeKind: "search", trigger: "arrive", window: nil, days: "", deadlineRule: "直近の金曜", note: "期限は yyyy-MM-dd で返る"),
        NLEvalCase(id: "ja08", language: "ja", text: "本屋の近くに来たら新刊を確認", titleKeyword: "新刊", placeQuery: "本屋", placeKind: "search", trigger: "arrive", window: nil, days: "", deadlineRule: nil, note: ""),
        NLEvalCase(id: "ja09", language: "ja", text: "夜、コンビニに着いたら明日の朝食を買う", titleKeyword: "朝食", placeQuery: "コンビニ", placeKind: "search", trigger: "arrive", window: "19:00-23:00", days: "", deadlineRule: nil, note: ""),
        NLEvalCase(id: "ja10", language: "ja", text: "月曜と木曜の朝、駅に着いたら定期を確認", titleKeyword: "定期", placeQuery: "駅", placeKind: "fav", trigger: "arrive", window: "06:00-10:00", days: "mon,thu", deadlineRule: nil, note: ""),
        NLEvalCase(id: "ja11", language: "ja", text: "カフェを出るときに忘れ物チェック", titleKeyword: "忘れ物", placeQuery: "カフェ", placeKind: "search", trigger: "leave", window: nil, days: "", deadlineRule: nil, note: ""),
        NLEvalCase(id: "ja12", language: "ja", text: "実家に着いたら母に荷物を渡す", titleKeyword: "荷物", placeQuery: "実家", placeKind: "fav", trigger: "arrive", window: nil, days: "", deadlineRule: nil, note: "「実家」が保存されていなければ地図で探す／候補なし"),
        NLEvalCase(id: "ja13", language: "ja", text: "昼、近くの薬局に寄ったら目薬", titleKeyword: "目薬", placeQuery: "薬局", placeKind: "search", trigger: "arrive", window: "11:00-14:00", days: "", deadlineRule: nil, note: ""),
        NLEvalCase(id: "ja14", language: "ja", text: "来週の日曜まで、ホームセンターに行ったら電球を買う", titleKeyword: "電球", placeQuery: "ホームセンター", placeKind: "search", trigger: "arrive", window: nil, days: "", deadlineRule: "来週の日曜", note: ""),
        NLEvalCase(id: "ja15", language: "ja", text: "会社を出たら、帰りに牛乳", titleKeyword: "牛乳", placeQuery: "会社", placeKind: "fav", trigger: "leave", window: nil, days: "", deadlineRule: nil, note: ""),
        NLEvalCase(id: "ja16", language: "ja", text: "図書館に着いたら本を返す", titleKeyword: "本", placeQuery: "図書館", placeKind: "search", trigger: "arrive", window: nil, days: "", deadlineRule: nil, note: ""),
        NLEvalCase(id: "ja17", language: "ja", text: "平日の夜、ジムを出るときにシェイカーを洗う", titleKeyword: "シェイカー", placeQuery: "ジム", placeKind: "fav", trigger: "leave", window: "19:00-23:00", days: "weekdays", deadlineRule: nil, note: ""),
        NLEvalCase(id: "ja18", language: "ja", text: "駅でも家でもなく、スタバに着いたら宿題", titleKeyword: "宿題", placeQuery: "スタバ", placeKind: "search", trigger: "arrive", window: nil, days: "", deadlineRule: nil, note: "否定を含む。場所は「スタバ」"),
        NLEvalCase(id: "ja19", language: "ja", text: "牛乳を買う", titleKeyword: "牛乳", placeQuery: "", placeKind: "none", trigger: "unspecified", window: nil, days: "", deadlineRule: nil, note: "場所なし。候補なしで地図選びになる"),
        NLEvalCase(id: "ja20", language: "ja", text: "駅に着いたら上司を殴る", titleKeyword: "", placeQuery: "", placeKind: "none", trigger: "unspecified", window: nil, days: "", deadlineRule: nil, note: "安全フィルタで断られうる。断られたら入力文が題になる"),
        NLEvalCase(id: "en01", language: "en", text: "Buy milk when I get to the station", titleKeyword: "milk", placeQuery: "station", placeKind: "fav", trigger: "arrive", window: nil, days: "", deadlineRule: nil, note: ""),
        NLEvalCase(id: "en02", language: "en", text: "On weekday evenings, stop by the drugstore near the station for detergent", titleKeyword: "detergent", placeQuery: "drugstore", placeKind: "search", trigger: "arrive", window: "16:00-19:00", days: "weekdays", deadlineRule: nil, note: ""),
        NLEvalCase(id: "en03", language: "en", text: "Remind me to take my keys when I leave home", titleKeyword: "keys", placeQuery: "home", placeKind: "fav", trigger: "leave", window: nil, days: "", deadlineRule: nil, note: ""),
        NLEvalCase(id: "en04", language: "en", text: "When I arrive at work, call the dentist", titleKeyword: "dentist", placeQuery: "work", placeKind: "fav", trigger: "arrive", window: nil, days: "", deadlineRule: nil, note: ""),
        NLEvalCase(id: "en05", language: "en", text: "Saturday morning, when I get to the gym, drink protein", titleKeyword: "protein", placeQuery: "gym", placeKind: "fav", trigger: "arrive", window: "06:00-10:00", days: "sat", deadlineRule: nil, note: ""),
        NLEvalCase(id: "en06", language: "en", text: "At the supermarket on weekends, buy eggs", titleKeyword: "eggs", placeQuery: "supermarket", placeKind: "search", trigger: "arrive", window: nil, days: "weekends", deadlineRule: nil, note: ""),
        NLEvalCase(id: "en07", language: "en", text: "By this Friday, mail the package when I reach the post office", titleKeyword: "package", placeQuery: "post office", placeKind: "search", trigger: "arrive", window: nil, days: "", deadlineRule: "直近の金曜", note: ""),
        NLEvalCase(id: "en08", language: "en", text: "When I leave the cafe, check I have my umbrella", titleKeyword: "umbrella", placeQuery: "cafe", placeKind: "search", trigger: "leave", window: nil, days: "", deadlineRule: nil, note: ""),
        NLEvalCase(id: "en09", language: "en", text: "Buy milk", titleKeyword: "milk", placeQuery: "", placeKind: "none", trigger: "unspecified", window: nil, days: "", deadlineRule: nil, note: "場所なし"),
        NLEvalCase(id: "en10", language: "en", text: "at night when I'm near a pharmacy buy eye drops", titleKeyword: "eye drops", placeQuery: "pharmacy", placeKind: "search", trigger: "arrive", window: "19:00-23:00", days: "", deadlineRule: nil, note: "小文字・句読点なし"),
    ]
}

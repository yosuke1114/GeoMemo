#if DEBUG
import SwiftData
import Foundation

/// スクリーンショット用デモデータ注入
/// 起動引数 "-seedDemoData" が渡されたときのみ実行
enum DemoDataSeeder {
    static func seedIfNeeded(context: ModelContext) {
        guard CommandLine.arguments.contains("-seedDemoData") else { return }

        // 既存データを全削除してクリーンな状態で挿入
        let existing = (try? context.fetch(FetchDescriptor<GeoMemo>())) ?? []
        existing.forEach { context.delete($0) }
        try? context.save()

        // init 引数順: title, note, lat, lon, radius, locationName, imageData,
        //              notifyOnEntry, notifyOnExit, exitDelayMinutes, createdAt,
        //              deadline, timeWindowStart, timeWindowEnd, activeDays,
        //              colorIndex, isFavorite, isRouteTrigger, waypointData,
        //              tags, customTags

        let memos: [GeoMemo] = [
            GeoMemo(
                title: "プレゼン資料を印刷する",
                note: "コンビニで10枚・A4カラー印刷\n会議は14時〜なので余裕を持って",
                latitude: 35.6984, longitude: 139.7731, radius: 100,
                locationName: "秋葉原駅",
                notifyOnEntry: true, notifyOnExit: false,
                colorIndex: 0, isFavorite: false,
                tags: [PresetTag.work.rawValue]
            ),
            GeoMemo(
                title: "夕食の食材を買う",
                note: "・鶏もも肉\n・ブロッコリー\n・たまご\n・牛乳",
                latitude: 35.7083, longitude: 139.7740, radius: 150,
                locationName: "アメ横 近く",
                notifyOnEntry: true, notifyOnExit: false,
                colorIndex: 3, isFavorite: true,
                tags: [PresetTag.shopping.rawValue]
            ),
            GeoMemo(
                title: "ランチのおすすめ",
                note: "2Fの窓際席がおすすめ。\nパスタランチセット ¥1,200",
                latitude: 35.7010, longitude: 139.7680, radius: 80,
                locationName: "末広町",
                notifyOnEntry: true, notifyOnExit: false,
                colorIndex: 2, isFavorite: true,
                tags: [PresetTag.food.rawValue]
            ),
            GeoMemo(
                title: "ゴミ出し — 燃えるゴミ",
                note: "収集は火・金の8時まで\n袋は指定の黄色い袋を使う",
                latitude: 35.6960, longitude: 139.7700, radius: 200,
                locationName: "外神田",
                notifyOnEntry: false, notifyOnExit: true,
                activeDays: [2, 5],
                colorIndex: 1, isFavorite: false,
                tags: [PresetTag.home.rawValue]
            ),
            GeoMemo(
                title: "歯医者の予約を確認",
                note: "次回: 来月15日 10:30〜\n保険証を忘れずに持参する",
                latitude: 35.7050, longitude: 139.7710, radius: 100,
                locationName: "御徒町クリニック",
                notifyOnEntry: true, notifyOnExit: false,
                colorIndex: 4, isFavorite: false,
                tags: [PresetTag.medical.rawValue]
            ),
        ]

        memos.forEach { context.insert($0) }
        try? context.save()
        print("[DemoDataSeeder] Inserted \(memos.count) demo memos")
    }
}
#endif

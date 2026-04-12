import Foundation
import SwiftData
import CoreLocation

@Model final class GeoMemo: Identifiable {
    var id: UUID = UUID()
    var title: String = ""
    var note: String = ""
    var latitude: Double = 0.0
    var longitude: Double = 0.0
    var radius: Double = 100.0
    var locationName: String = ""
    var imageData: Data?
    var notifyOnEntry: Bool = true
    var notifyOnExit: Bool = true
    var createdAt: Date = Date()
    var deadline: Date?
    var timeWindowStart: Int?  // 分換算（例：600 = 10:00）
    var timeWindowEnd: Int?    // 分換算（例：1200 = 20:00）
    var activeDays: [Int]?     // 0=日〜6=土（nilなら毎日）
    var colorIndex: Int = 0    // MemoColor rawValue (0=blue default)
    var isFavorite: Bool = false
    var isDone: Bool = false
    /// 退出後タイマー（分）。nil = 即通知、値あり = 退出からN分後に通知
    var exitDelayMinutes: Int? = nil

    // Route trigger
    var isRouteTrigger: Bool = false
    var waypointData: Data?    // JSON-encoded [RouteWaypoint]

    // Tags (Phase 2)
    var tags: [Int] = []          // PresetTag rawValue の配列
    var customTags: [String] = [] // フリーテキストタグ（上限: GeoMemoLimits.maxCustomTags）

    // Pass-through notification (v1.1)
    /// true のとき、ジオフェンス半径300m手前からDynamic Islandに接近情報を表示する
    var notifyOnPass: Bool = false

    // List / Checklist mode (v1.2)
    /// true のとき、note の代わりにチェックリスト形式でアイテムを管理する
    var isListMode: Bool = false
    /// JSON-encoded [ListItem]
    var listItemsData: Data?

    /// タイトルが未設定かどうか（空文字 or 旧データの "Untitled"/"（タイトルなし）" 相当）
    var isUntitled: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
            || trimmed == "Untitled"
            || trimmed == "（タイトルなし）"
    }

    /// 表示用タイトル（未設定時は "(タイトルなし)"）
    var displayTitle: String {
        isUntitled ? String(localized: "Untitled") : title
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var region: CLCircularRegion? {
        CLCircularRegion(center: coordinate, radius: radius, identifier: id.uuidString)
    }

    init(title: String, note: String, latitude: Double, longitude: Double, radius: Double, locationName: String = "", imageData: Data? = nil, notifyOnEntry: Bool = true, notifyOnExit: Bool = true, exitDelayMinutes: Int? = nil, createdAt: Date = Date(), deadline: Date? = nil, timeWindowStart: Int? = nil, timeWindowEnd: Int? = nil, activeDays: [Int]? = nil, colorIndex: Int = 0, isFavorite: Bool = false, isRouteTrigger: Bool = false, waypointData: Data? = nil, tags: [Int] = [], customTags: [String] = []) {
        self.id = UUID()
        self.title = title
        self.note = note
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.locationName = locationName
        self.imageData = imageData
        self.notifyOnEntry = notifyOnEntry
        self.notifyOnExit = notifyOnExit
        self.exitDelayMinutes = exitDelayMinutes
        self.createdAt = createdAt
        self.deadline = deadline
        self.timeWindowStart = timeWindowStart
        self.timeWindowEnd = timeWindowEnd
        self.activeDays = activeDays
        self.colorIndex = colorIndex
        self.isFavorite = isFavorite
        self.isRouteTrigger = isRouteTrigger
        self.waypointData = waypointData
        self.tags = tags
        self.customTags = customTags
    }
}

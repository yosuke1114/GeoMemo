import Foundation
import SwiftData
import CoreLocation

@Model final class GeoMemo: Identifiable {
    @Attribute(.unique) var id: UUID
    var title: String
    var note: String
    var latitude: Double
    var longitude: Double
    var radius: Double
    var locationName: String
    var imageData: Data?
    var notifyOnEntry: Bool
    var notifyOnExit: Bool
    var createdAt: Date
    var deadline: Date?
    var timeWindowStart: Int?  // 分換算（例：600 = 10:00）
    var timeWindowEnd: Int?    // 分換算（例：1200 = 20:00）
    var activeDays: [Int]?     // 0=日〜6=土（nilなら毎日）

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var region: CLCircularRegion? {
        CLCircularRegion(center: coordinate, radius: radius, identifier: id.uuidString)
    }

    init(title: String, note: String, latitude: Double, longitude: Double, radius: Double, locationName: String = "", imageData: Data? = nil, notifyOnEntry: Bool = true, notifyOnExit: Bool = true, createdAt: Date = Date(), deadline: Date? = nil, timeWindowStart: Int? = nil, timeWindowEnd: Int? = nil, activeDays: [Int]? = nil) {
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
        self.createdAt = createdAt
        self.deadline = deadline
        self.timeWindowStart = timeWindowStart
        self.timeWindowEnd = timeWindowEnd
        self.activeDays = activeDays
    }
}

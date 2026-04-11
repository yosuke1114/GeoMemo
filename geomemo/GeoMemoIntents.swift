import AppIntents
import CoreLocation
import MapKit
import SwiftData

// MARK: - Notification Names for Deep Linking

extension Notification.Name {
    static let openGeoMemo = Notification.Name("openGeoMemo")
    static let showGeoMemoFavorites = Notification.Name("showGeoMemoFavorites")
    static let searchGeoMemos = Notification.Name("searchGeoMemos")
}

// MARK: - Open Memo Intent

struct OpenGeoMemoIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open GeoMemo"
    static var description: IntentDescription = "Opens a specific memo in GeoMemo"

    @Parameter(title: "Memo")
    var target: GeoMemoEntity

    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .openGeoMemo, object: target.id)
        return .result()
    }
}

// MARK: - Show Favorites Intent

struct ShowFavoritesIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Favorites"
    static var description: IntentDescription = "Shows favorite memos in GeoMemo"

    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .showGeoMemoFavorites, object: nil)
        return .result()
    }
}

// MARK: - List Nearby Memos Intent

struct ListNearbyMemosIntent: AppIntent {
    static var title: LocalizedStringResource = "Nearby Memos"
    static var description: IntentDescription = "Lists GeoMemo memos near your current location"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let allMemos: [GeoMemo]
        do {
            allMemos = try GeoMemoStore.fetchAll()
        } catch {
            return .result(dialog: "Failed to fetch memos.")
        }

        let locationManager = CLLocationManager()
        guard let currentLocation = locationManager.location else {
            return .result(dialog: "Could not get your current location.")
        }

        let nearbyMemos = allMemos
            .map { memo -> (GeoMemo, Double) in
                let memoLocation = CLLocation(latitude: memo.latitude, longitude: memo.longitude)
                let distance = currentLocation.distance(from: memoLocation)
                return (memo, distance)
            }
            .filter { $0.1 <= 5000 }
            .sorted { $0.1 < $1.1 }
            .prefix(5)

        if nearbyMemos.isEmpty {
            return .result(dialog: "No memos nearby.")
        }

        let list = nearbyMemos.map { memo, distance in
            let distanceText = distance < 1000
                ? "\(Int(distance))m"
                : String(format: "%.1fkm", distance / 1000)
            return "\(memo.title)（\(distanceText)）"
        }.joined(separator: "、")

        return .result(dialog: "\(nearbyMemos.count) memos nearby: \(list)")
    }
}

// MARK: - Mark Memo Done Intent

struct MarkMemoDoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Memo"
    static var description: IntentDescription = "Marks a GeoMemo memo as complete"

    @Parameter(title: "Memo")
    var target: GeoMemoEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try GeoMemoStore.markDone(id: target.id)
        // アプリがフォアグラウンドにいる場合は NotificationCenter でも同期
        await MainActor.run {
            NotificationCenter.default.post(name: .geoMemoMarkDone, object: target.id.uuidString)
        }
        return .result(dialog: "\"\(target.title)\" \(String(localized: "marked as complete"))")
    }
}

// MARK: - Add Memo Intent

struct AddGeoMemoIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Memo"
    static var description: IntentDescription = "Creates a new memo at your current location in GeoMemo"

    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Title")
    var title: String

    @Parameter(title: "Note", default: "")
    var note: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 現在地を取得
        let locationManager = CLLocationManager()
        let location = locationManager.location
        let latitude  = location?.coordinate.latitude  ?? 35.6812
        let longitude = location?.coordinate.longitude ?? 139.7671

        // 逆ジオコーディング
        var locationName = ""
        if let loc = location {
            if let request = MKReverseGeocodingRequest(location: loc),
               let item = try? await request.mapItems.first {
                let repr = item.addressRepresentations
                locationName = repr?.cityWithContext ?? repr?.cityName ?? item.name ?? ""
            }
        }

        try GeoMemoStore.insert(
            title: title,
            note: note,
            latitude: latitude,
            longitude: longitude,
            locationName: locationName
        )

        return .result(dialog: "Memo \"\(title)\" added\(locationName.isEmpty ? "" : " at \(locationName)")")
    }
}

// MARK: - Get Nearby Memos Intent

struct GetNearbyMemosIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Nearby Memos"
    static var description: IntentDescription = "Returns GeoMemo memos near your current location — use the result in subsequent Shortcuts actions"

    @Parameter(title: "Radius (meters)", default: 1000)
    var radiusMeters: Int

    func perform() async throws -> some IntentResult & ReturnsValue<[GeoMemoEntity]> & ProvidesDialog {
        let allMemos: [GeoMemo]
        do {
            allMemos = try GeoMemoStore.fetchAll()
        } catch {
            return .result(value: [], dialog: "Failed to fetch memos.")
        }

        let locationManager = CLLocationManager()
        guard let currentLocation = locationManager.location else {
            return .result(value: [], dialog: "Could not get your current location.")
        }

        let radius = Double(max(1, radiusMeters))
        let nearby = allMemos
            .filter { !$0.isDone }
            .map { memo -> (GeoMemo, Double) in
                let memoLocation = CLLocation(latitude: memo.latitude, longitude: memo.longitude)
                return (memo, currentLocation.distance(from: memoLocation))
            }
            .filter { $0.1 <= radius }
            .sorted { $0.1 < $1.1 }

        let entities = nearby.map { GeoMemoEntity(from: $0.0) }

        let dialogText = nearby.isEmpty
            ? "No memos within \(radiusMeters)m."
            : "\(nearby.count) memos found nearby."

        return .result(value: entities, dialog: IntentDialog(stringLiteral: dialogText))
    }
}

// MARK: - Search Intent

struct SearchGeoMemosIntent: AppIntent {
    static var title: LocalizedStringResource = "Search GeoMemo"
    static var description: IntentDescription = "Search for memos in GeoMemo"

    @Parameter(title: "Search Text")
    var query: String

    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .searchGeoMemos, object: query)
        return .result()
    }
}

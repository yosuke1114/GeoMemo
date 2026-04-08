import AppIntents
import CoreLocation

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

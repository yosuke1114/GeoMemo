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
    static let title: LocalizedStringResource = "Open GeoMemo"
    static let description: IntentDescription = "Opens a specific memo in GeoMemo"

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
    static let title: LocalizedStringResource = "Show Favorites"
    static let description: IntentDescription = "Shows favorite memos in GeoMemo"

    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .showGeoMemoFavorites, object: nil)
        return .result()
    }
}

// MARK: - List Nearby Memos Intent

struct ListNearbyMemosIntent: AppIntent {
    static let title: LocalizedStringResource = "Nearby Memos"
    static let description: IntentDescription = "Lists GeoMemo memos near your current location"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let allEntities: [GeoMemoEntity]
        do {
            allEntities = try GeoMemoStore.fetchAllEntities()
        } catch {
            return .result(dialog: "Failed to fetch memos.")
        }

        guard let currentLocation = await AddGeoMemoIntent.currentLocation() else {
            return .result(dialog: "Could not get your current location.")
        }

        let nearbyMemos = allEntities
            .filter { !$0.isDone }  // GetNearbyMemosIntent と挙動を揃え、完了済みは除外する
            .map { entity -> (GeoMemoEntity, Double) in
                let memoLocation = CLLocation(latitude: entity.latitude, longitude: entity.longitude)
                let distance = currentLocation.distance(from: memoLocation)
                return (entity, distance)
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
    static let title: LocalizedStringResource = "Complete Memo"
    static let description: IntentDescription = "Marks a GeoMemo memo as complete"

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
    static let title: LocalizedStringResource = "Add Memo"
    static let description: IntentDescription = "Creates a new memo at your current location in GeoMemo"

    static var openAppWhenRun: Bool { false }
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Title")
    var title: String

    @Parameter(title: "Note", default: "")
    var note: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 現在地が取れない時に Tokyo へフォールバックするとゴーストメモになるため、
        // 位置取得に失敗した場合は中止してダイアログで通知する。
        guard let location = await Self.currentLocation() else {
            return .result(dialog: "Could not get your current location.")
        }

        // 逆ジオコーディング
        var locationName = ""
        if let request = MKReverseGeocodingRequest(location: location),
           let item = try? await request.mapItems.first {
            let repr = item.addressRepresentations
            locationName = repr?.cityWithContext ?? repr?.cityName ?? item.name ?? ""
        }

        try GeoMemoStore.insert(
            title: title,
            note: note,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            locationName: locationName
        )

        return .result(dialog: "Memo \"\(title)\" added\(locationName.isEmpty ? "" : " at \(locationName)")")
    }

    /// CLLocationManager().location は監視開始前は常に nil なので、
    /// CLLocationUpdate.liveUpdates で実際の 1 件目を待つ。タイムアウトは 5 秒。
    fileprivate static func currentLocation() async -> CLLocation? {
        await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let loc = update.location { return loc }
                    }
                } catch {
                    return nil
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }
}

// MARK: - Add Memo At Favorite Place Intent

enum AddPlaceError: Error, CustomLocalizedStringResourceConvertible {
    case storeUnavailable

    var localizedStringResource: LocalizedStringResource {
        "Could not open your memos. Try again after unlocking your device."
    }
}

/// 現在地ではなく、保存済みの「お気に入りの場所」を指定してメモを追加する。
/// 無料版の件数の上限は、現在地への追加（`AddGeoMemoIntent`）や Watch のクイック追加と同じく、ここでは掛けない。
struct AddGeoMemoAtPlaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Memo at Favorite Place"
    static let description: IntentDescription = "Creates a new memo at one of your saved favorite places in GeoMemo"

    static var openAppWhenRun: Bool { false }
    // ロック中の Siri から場所の名前・住所が出ないようにする
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Favorite Place")
    var place: FavoritePlaceEntity

    @Parameter(title: "Title")
    var title: String

    @Parameter(title: "Note", default: "")
    var note: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) at \(\.$place)") {
            \.$note
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // ショートカットに残った古い値ではなく、保存されている最新の場所（編集・削除を反映）を使う。
        // 保存先を開けない失敗は「場所が無い」と区別して投げ、ショートカットの後続を止める。
        let candidates: [PlaceCandidate]
        do {
            candidates = try GeoMemoStore.fetchFavoritePlaceCandidates()
        } catch {
            throw AddPlaceError.storeUnavailable
        }
        guard let current = candidates.first(where: { $0.id == place.id }) else {
            return .result(dialog: "That favorite place no longer exists.")
        }
        guard let draft = PlaceMemoDraft.make(title: title, note: note, place: current) else {
            return .result(dialog: "Could not add the memo. Check the title and the place.")
        }

        try GeoMemoStore.insert(
            title: draft.title,
            note: draft.note,
            latitude: draft.latitude,
            longitude: draft.longitude,
            locationName: draft.locationName,
            radius: draft.radius
        )

        // 画面が開いていなくても、追加したメモの領域を登録する（上限・優先順は GeofenceReconciler に任せる）。
        await MainActor.run { Self.reconcileGeofences() }

        return .result(dialog: "Memo \"\(draft.title)\" added at \(draft.locationName)")
    }

    @MainActor
    private static func reconcileGeofences() {
        guard let container = try? GeoMemoStore.sharedContainer() else { return }
        let context = ModelContext(container)
        let memos = (try? context.fetch(FetchDescriptor<GeoMemo>())) ?? []
        let shared = (try? context.fetch(FetchDescriptor<SharedMemo>())) ?? []
        GeofenceReconciler.reconcile(memos: memos, sharedMemos: shared)
    }
}

// MARK: - Get Nearby Memos Intent

struct GetNearbyMemosIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Nearby Memos"
    static let description: IntentDescription = "Returns GeoMemo memos near your current location — use the result in subsequent Shortcuts actions"

    @Parameter(title: "Radius (meters)", default: 1000)
    var radiusMeters: Int

    func perform() async throws -> some IntentResult & ReturnsValue<[GeoMemoEntity]> & ProvidesDialog {
        let allEntities: [GeoMemoEntity]
        do {
            allEntities = try GeoMemoStore.fetchAllEntities()
        } catch {
            return .result(value: [], dialog: "Failed to fetch memos.")
        }

        guard let currentLocation = await AddGeoMemoIntent.currentLocation() else {
            return .result(value: [], dialog: "Could not get your current location.")
        }

        let radius = Double(max(1, radiusMeters))
        let nearby = allEntities
            .filter { !$0.isDone }
            .map { entity -> (GeoMemoEntity, Double) in
                let memoLocation = CLLocation(latitude: entity.latitude, longitude: entity.longitude)
                return (entity, currentLocation.distance(from: memoLocation))
            }
            .filter { $0.1 <= radius }
            .sorted { $0.1 < $1.1 }

        let entities = nearby.map { $0.0 }

        let dialogText = nearby.isEmpty
            ? "No memos within \(radiusMeters)m."
            : "\(nearby.count) memos found nearby."

        return .result(value: entities, dialog: IntentDialog(stringLiteral: dialogText))
    }
}

// MARK: - Search Intent

struct SearchGeoMemosIntent: AppIntent {
    static let title: LocalizedStringResource = "Search GeoMemo"
    static let description: IntentDescription = "Search for memos in GeoMemo"

    @Parameter(title: "Search Text")
    var query: String

    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .searchGeoMemos, object: query)
        return .result()
    }
}

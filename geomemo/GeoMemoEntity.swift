import AppIntents
@preconcurrency import SwiftData
import Foundation
import CoreSpotlight

// MARK: - Shared SwiftData Access

/// Standalone SwiftData container for use outside SwiftUI (App Intents, Spotlight).
enum GeoMemoStore {
    static let appGroupID = "group.com.yokuro.geomemo"

    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([GeoMemo.self])
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("geomemo.store") else {
            throw StoreError.appGroupUnavailable
        }
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    static func fetchAll() throws -> [GeoMemo] {
        let container = try makeContainer()
        let context = ModelContext(container)
        return try context.fetch(
            FetchDescriptor<GeoMemo>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
    }

    enum StoreError: Error {
        case appGroupUnavailable
    }
}

// MARK: - App Entity

struct GeoMemoEntity: AppEntity, IndexedEntity {
    static var defaultQuery = GeoMemoEntityQuery()
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "GeoMemo"

    var id: UUID
    var title: String
    var locationName: String
    var note: String
    var isFavorite: Bool
    var colorIndex: Int
    var latitude: Double
    var longitude: Double

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(locationName)"
        )
    }

    // MARK: IndexedEntity — Spotlight

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet()
        attributes.displayName = title
        attributes.contentDescription = note.isEmpty ? locationName : "\(locationName) — \(note)"
        attributes.namedLocation = locationName
        attributes.latitude = NSNumber(value: latitude)
        attributes.longitude = NSNumber(value: longitude)
        attributes.supportsNavigation = true as NSNumber
        return attributes
    }

    init(from memo: GeoMemo) {
        self.id = memo.id
        self.title = memo.title.isEmpty ? String(localized: "Untitled") : memo.title
        self.locationName = memo.locationName
        self.note = memo.note
        self.isFavorite = memo.isFavorite
        self.colorIndex = memo.colorIndex
        self.latitude = memo.latitude
        self.longitude = memo.longitude
    }
}

// MARK: - Entity Query

struct GeoMemoEntityQuery: EntityQuery, EntityStringQuery {

    func entities(for identifiers: [UUID]) async throws -> [GeoMemoEntity] {
        let allMemos = try GeoMemoStore.fetchAll()
        let idSet = Set(identifiers)
        return allMemos
            .filter { idSet.contains($0.id) }
            .map { GeoMemoEntity(from: $0) }
    }

    func suggestedEntities() async throws -> [GeoMemoEntity] {
        let allMemos = try GeoMemoStore.fetchAll()
        let sorted = allMemos.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            return lhs.createdAt > rhs.createdAt
        }
        return Array(sorted.prefix(8)).map { GeoMemoEntity(from: $0) }
    }

    func entities(matching string: String) async throws -> [GeoMemoEntity] {
        let allMemos = try GeoMemoStore.fetchAll()
        return allMemos
            .filter {
                $0.title.localizedCaseInsensitiveContains(string) ||
                $0.locationName.localizedCaseInsensitiveContains(string) ||
                $0.note.localizedCaseInsensitiveContains(string)
            }
            .map { GeoMemoEntity(from: $0) }
    }
}

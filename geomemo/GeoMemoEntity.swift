import AppIntents
import SwiftData
import Foundation
import CoreSpotlight

// MARK: - Shared SwiftData Access

/// Standalone SwiftData container for use outside SwiftUI (App Intents, Spotlight).
enum GeoMemoStore {
    nonisolated static let appGroupID          = "group.com.yokuro.geomemo"
    nonisolated static let cloudKitContainerID = "iCloud.com.yokuro.geomemo"

    /// アプリ本体と Spotlight/App Intents で同じスキーマを共有する。
    /// ここを App 側 (geomemoApp.sharedModelContainer) と揃えないと、
    /// 同じ App Group の `geomemo.store` を別構成で開いてしまい migration が失敗する。
    nonisolated static func makeSchema() -> Schema {
        Schema([
            GeoMemo.self,
            FavoritePlace.self,
            UserProfile.self,
            FriendConnection.self,
            SharedMemo.self
        ])
    }

    nonisolated static func makeContainer() throws -> ModelContainer {
        let schema = makeSchema()
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("geomemo.store") else {
            throw StoreError.appGroupUnavailable
        }
        #if targetEnvironment(simulator)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        #else
        let useCloudKit = FileManager.default.ubiquityIdentityToken != nil
        let config = ModelConfiguration(
            schema: schema,
            url: url,
            cloudKitDatabase: useCloudKit ? .private(cloudKitContainerID) : .none
        )
        #endif
        return try ModelContainer(
            for: schema,
            migrationPlan: GeoMemoMigrationPlan.self,
            configurations: [config]
        )
    }

    /// プロセス内で再利用するコンテナ。App Intent / Spotlight の各呼び出しごとに
    /// `ModelContainer` を作り直すと SQLite + CloudKit の初期化で 100ms+ かかるため。
    /// 初回失敗時は次回再試行できるよう Optional + lazy で持つ。
    nonisolated private static let cachedContainerBox = ContainerBox()

    nonisolated private final class ContainerBox: @unchecked Sendable {
        let lock = NSLock()
        var container: ModelContainer?
    }

    nonisolated static func sharedContainer() throws -> ModelContainer {
        cachedContainerBox.lock.lock()
        defer { cachedContainerBox.lock.unlock() }
        if let c = cachedContainerBox.container { return c }
        let c = try makeContainer()
        cachedContainerBox.container = c
        return c
    }

    /// nonisolated context（App Intents / Spotlight）から呼ばれるため、Sendable な
    /// `GeoMemoEntity` で返す。@Model は Sendable ではないのでクロスアクター漏出を防ぐ。
    nonisolated static func fetchAllEntities() throws -> [GeoMemoEntity] {
        let container = try sharedContainer()
        let context = ModelContext(container)
        let models = try context.fetch(
            FetchDescriptor<GeoMemo>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
        return models.map { GeoMemoEntity(from: $0) }
    }

    /// 指定 ID のメモを完了済みにする
    nonisolated static func markDone(id: UUID) throws {
        let container = try sharedContainer()
        let context = ModelContext(container)
        let memos = try context.fetch(FetchDescriptor<GeoMemo>())
        guard let memo = memos.first(where: { $0.id == id }) else { return }
        memo.isDone = true
        try context.save()
    }

    /// 新しいメモを挿入する（AppIntentsからの作成用）
    nonisolated static func insert(title: String, note: String, latitude: Double, longitude: Double, locationName: String) throws {
        let container = try sharedContainer()
        let context = ModelContext(container)
        let memo = GeoMemo(
            title: title,
            note: note,
            latitude: latitude,
            longitude: longitude,
            radius: 100
        )
        memo.locationName = locationName
        context.insert(memo)
        try context.save()
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
    var isDone: Bool
    var colorIndex: Int
    var latitude: Double
    var longitude: Double
    var tags: [Int]
    var customTags: [String]
    var createdAt: Date

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
        // タグをSpotlightキーワードに追加
        let presetKeywords = tags.compactMap { PresetTag(rawValue: $0)?.localizedName }
        let allKeywords = presetKeywords + customTags
        if !allKeywords.isEmpty {
            attributes.keywords = allKeywords
        }
        return attributes
    }

    init(from memo: GeoMemo) {
        self.id = memo.id
        self.title = memo.title.isEmpty ? String(localized: "Untitled") : memo.title
        self.locationName = memo.locationName
        self.note = memo.note
        self.isFavorite = memo.isFavorite
        self.isDone = memo.isDone
        self.colorIndex = memo.colorIndex
        self.latitude = memo.latitude
        self.longitude = memo.longitude
        self.tags = memo.tags
        self.customTags = memo.customTags
        self.createdAt = memo.createdAt
    }
}

// MARK: - Entity Query

struct GeoMemoEntityQuery: EntityQuery, EntityStringQuery {

    func entities(for identifiers: [UUID]) async throws -> [GeoMemoEntity] {
        // Spotlight タップ / Shortcut 入力ごとに走る hot path。predicate を SQL 側に押し込んで
        // 全件 fetch + 後フィルタを避ける。
        let idSet = Set(identifiers)
        let descriptor = FetchDescriptor<GeoMemo>(
            predicate: #Predicate { idSet.contains($0.id) }
        )
        let context = ModelContext(try GeoMemoStore.sharedContainer())
        return try context.fetch(descriptor).map { GeoMemoEntity(from: $0) }
    }

    func suggestedEntities() async throws -> [GeoMemoEntity] {
        // Bool は Swift 標準で Comparable ではないので SortDescriptor に直接渡せない。
        // createdAt で SQL 側ソートし、isFavorite の優先付けは Swift 側で行う。
        var descriptor = FetchDescriptor<GeoMemo>(
            predicate: #Predicate { !$0.isDone },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 32
        let context = ModelContext(try GeoMemoStore.sharedContainer())
        let memos = try context.fetch(descriptor)
        let sorted = memos.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            return lhs.createdAt > rhs.createdAt
        }
        return sorted.prefix(8).map { GeoMemoEntity(from: $0) }
    }

    func entities(matching string: String) async throws -> [GeoMemoEntity] {
        let descriptor = FetchDescriptor<GeoMemo>(
            predicate: #Predicate {
                $0.title.localizedStandardContains(string) ||
                $0.locationName.localizedStandardContains(string) ||
                $0.note.localizedStandardContains(string)
            }
        )
        let context = ModelContext(try GeoMemoStore.sharedContainer())
        return try context.fetch(descriptor).map { GeoMemoEntity(from: $0) }
    }
}

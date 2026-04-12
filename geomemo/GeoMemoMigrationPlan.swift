import Foundation
import SwiftData

// MARK: - Schema V1（タグ追加前）

enum GeoMemoSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [GeoMemoV1.self] }

    @Model final class GeoMemoV1 {
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
        var timeWindowStart: Int?
        var timeWindowEnd: Int?
        var activeDays: [Int]?
        var colorIndex: Int = 0
        var isFavorite: Bool = false
        var isRouteTrigger: Bool = false
        var waypointData: Data?

        init() {}
    }
}

// MARK: - Schema V2（タグ追加後）

enum GeoMemoSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [GeoMemoV2.self] }

    @Model final class GeoMemoV2 {
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
        var timeWindowStart: Int?
        var timeWindowEnd: Int?
        var activeDays: [Int]?
        var colorIndex: Int = 0
        var isFavorite: Bool = false
        var isRouteTrigger: Bool = false
        var waypointData: Data?
        var tags: [Int] = []
        var customTags: [String] = []

        init() {}
    }
}

// MARK: - Schema V3（notifyOnPass 追加）

enum GeoMemoSchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] { [GeoMemo.self] }
    // GeoMemo本体（notifyOnPass フィールド追加済み、デフォルト false）
}

// MARK: - Migration Plan

enum GeoMemoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [GeoMemoSchemaV1.self, GeoMemoSchemaV2.self, GeoMemoSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [
            // V1→V2: tags / customTags はデフォルト値あり → lightweight
            MigrationStage.lightweight(
                fromVersion: GeoMemoSchemaV1.self,
                toVersion: GeoMemoSchemaV2.self
            ),
            // V2→V3: notifyOnPass はデフォルト false → lightweight
            MigrationStage.lightweight(
                fromVersion: GeoMemoSchemaV2.self,
                toVersion: GeoMemoSchemaV3.self
            )
        ]
    }
}

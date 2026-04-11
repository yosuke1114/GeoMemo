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
    static var models: [any PersistentModel.Type] { [GeoMemo.self] }
    // GeoMemo本体（tags / customTags フィールド追加済み）
}

// MARK: - Migration Plan

enum GeoMemoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [GeoMemoSchemaV1.self, GeoMemoSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            // tags / customTags はデフォルト値あり → lightweight で自動補完
            MigrationStage.lightweight(
                fromVersion: GeoMemoSchemaV1.self,
                toVersion: GeoMemoSchemaV2.self
            )
        ]
    }
}

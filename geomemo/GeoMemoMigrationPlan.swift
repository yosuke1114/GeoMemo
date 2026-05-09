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
    static var models: [any PersistentModel.Type] { [GeoMemoV3.self] }

    @Model final class GeoMemoV3 {
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
        var isDone: Bool = false
        var exitDelayMinutes: Int?
        var isRouteTrigger: Bool = false
        var waypointData: Data?
        var tags: [Int] = []
        var customTags: [String] = []
        var notifyOnPass: Bool = false

        init() {}
    }
}

// MARK: - Schema V4（isListMode / listItemsData 追加）

enum GeoMemoSchemaV4: VersionedSchema {
    static var versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] { [GeoMemoV4.self] }

    @Model final class GeoMemoV4 {
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
        var isDone: Bool = false
        var exitDelayMinutes: Int?
        var isRouteTrigger: Bool = false
        var waypointData: Data?
        var tags: [Int] = []
        var customTags: [String] = []
        var notifyOnPass: Bool = false
        var isListMode: Bool = false
        var listItemsData: Data?

        init() {}
    }
}

// MARK: - Schema V5（dwellMinutes 追加）

enum GeoMemoSchemaV5: VersionedSchema {
    static var versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] { [GeoMemoV5.self] }

    @Model final class GeoMemoV5 {
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
        var isDone: Bool = false
        var exitDelayMinutes: Int?
        var isRouteTrigger: Bool = false
        var waypointData: Data?
        var tags: [Int] = []
        var customTags: [String] = []
        var notifyOnPass: Bool = false
        var isListMode: Bool = false
        var listItemsData: Data?
        var dwellMinutes: Int?

        init() {}
    }
}

// MARK: - Schema V6（FavoritePlace 追加）

enum GeoMemoSchemaV6: VersionedSchema {
    static var versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] { [GeoMemo.self, FavoritePlace.self] }
    // V6: GeoMemo は V5 から変更なし。FavoritePlace テーブルを新規追加
}

// MARK: - Migration Plan

enum GeoMemoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [GeoMemoSchemaV1.self, GeoMemoSchemaV2.self, GeoMemoSchemaV3.self,
         GeoMemoSchemaV4.self, GeoMemoSchemaV5.self, GeoMemoSchemaV6.self]
    }

    static var stages: [MigrationStage] {
        [
            MigrationStage.lightweight(
                fromVersion: GeoMemoSchemaV1.self,
                toVersion: GeoMemoSchemaV2.self
            ),
            MigrationStage.lightweight(
                fromVersion: GeoMemoSchemaV2.self,
                toVersion: GeoMemoSchemaV3.self
            ),
            MigrationStage.lightweight(
                fromVersion: GeoMemoSchemaV3.self,
                toVersion: GeoMemoSchemaV4.self
            ),
            MigrationStage.lightweight(
                fromVersion: GeoMemoSchemaV4.self,
                toVersion: GeoMemoSchemaV5.self
            ),
            // V5→V6: FavoritePlace テーブル追加、既存 GeoMemo は変更なし → lightweight
            MigrationStage.lightweight(
                fromVersion: GeoMemoSchemaV5.self,
                toVersion: GeoMemoSchemaV6.self
            )
        ]
    }
}

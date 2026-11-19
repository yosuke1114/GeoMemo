import Foundation
import SwiftData

// MARK: - Schema V1（タグ追加前）

enum GeoMemoSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [GeoMemo.self] }

    @Model final class GeoMemo {
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
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [GeoMemo.self] }

    @Model final class GeoMemo {
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
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] { [GeoMemo.self] }

    @Model final class GeoMemo {
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
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] { [GeoMemo.self] }

    @Model final class GeoMemo {
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
    static let versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] { [GeoMemo.self] }

    @Model final class GeoMemo {
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
    static let versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] {
        [GeoMemoSchemaV5.GeoMemo.self, FavoritePlace.self]
    }
    // V6: GeoMemo は V5 から変更なし（GeoMemo を流用）。FavoritePlace テーブルを新規追加。

    @Model final class FavoritePlace {
        var id: UUID = UUID()
        var name: String = ""
        var subtitle: String = ""
        var latitude: Double = 0.0
        var longitude: Double = 0.0
        var iconName: String = "mappin.fill"
        var createdAt: Date = Date()
        init() {}
    }
}

// MARK: - Schema V7（UserProfile / FriendConnection 追加）

enum GeoMemoSchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        [GeoMemoSchemaV5.GeoMemo.self,
         GeoMemoSchemaV6.FavoritePlace.self,
         UserProfile.self,
         FriendConnection.self]
    }
    // V7: GeoMemo / FavoritePlace は変更なし。UserProfile / FriendConnection を新規追加。

    @Model final class UserProfile {
        var id: UUID = UUID()
        var displayName: String = ""
        var iCloudRecordID: String = ""
        var createdAt: Date = Date()
        init() {}
    }

    @Model final class FriendConnection {
        var id: UUID = UUID()
        var friendRecordID: String = ""
        var friendDisplayName: String = ""
        var statusRaw: String = "pending"
        var inviteCode: String = ""
        var createdAt: Date = Date()
        init() {}
    }
}

// MARK: - Schema V8（SharedMemo 追加）

enum GeoMemoSchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)
    static var models: [any PersistentModel.Type] {
        [GeoMemoSchemaV5.GeoMemo.self,
         GeoMemoSchemaV6.FavoritePlace.self,
         GeoMemoSchemaV7.UserProfile.self,
         GeoMemoSchemaV7.FriendConnection.self,
         SharedMemo.self]
    }
    // V8: SharedMemo テーブルを新規追加。
    // ※ スナップショット型は live model と同じ型名にすること（SwiftData の entity 名は型名で決まり、
    //   端末のストアは live 名で作られているため。名前が違うと staged migration が既存ストアを識別できない）。
    //   live model の schema を変更したら `GeoMemoSchemaV9` を新設し、変更したモデルのスナップショットを
    //   同名で定義して migration stage を追加する。MigrationStoreTests が一致を検証する（docs/adr/0001）。

    @Model final class SharedMemo {
        var id: UUID = UUID()
        var ckRecordName: String = ""
        var memoTitle: String = ""
        var memoLocationName: String = ""
        var memoLatitude: Double = 0.0
        var memoLongitude: Double = 0.0
        var memoRadius: Double = 100.0
        var memoDeadline: Date? = nil
        var memoTimeWindowStart: Int? = nil
        var memoTimeWindowEnd: Int? = nil
        var requesterRecordID: String = ""
        var requesterName: String = ""
        var recipientRecordID: String = ""
        var recipientName: String = ""
        var autoComplete: Bool = false
        var statusRaw: String = "active"
        var firedAt: Date? = nil
        var completedAt: Date? = nil
        var createdAt: Date = Date()
        var isMyRequest: Bool = false
        init() {}
    }
}

// MARK: - Migration Plan

enum GeoMemoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [GeoMemoSchemaV1.self, GeoMemoSchemaV2.self, GeoMemoSchemaV3.self,
         GeoMemoSchemaV4.self, GeoMemoSchemaV5.self, GeoMemoSchemaV6.self,
         GeoMemoSchemaV7.self, GeoMemoSchemaV8.self]
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
            // V5→V6: FavoritePlace テーブル追加
            MigrationStage.lightweight(
                fromVersion: GeoMemoSchemaV5.self,
                toVersion: GeoMemoSchemaV6.self
            ),
            // V6→V7: UserProfile / FriendConnection テーブル追加
            MigrationStage.lightweight(
                fromVersion: GeoMemoSchemaV6.self,
                toVersion: GeoMemoSchemaV7.self
            ),
            // V7→V8: SharedMemo テーブル追加
            MigrationStage.lightweight(
                fromVersion: GeoMemoSchemaV7.self,
                toVersion: GeoMemoSchemaV8.self
            )
        ]
    }
}

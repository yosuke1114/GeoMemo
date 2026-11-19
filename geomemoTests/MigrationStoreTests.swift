import Testing
import Foundation
import SwiftData
@testable import geomemo

/// 実際に利用者の端末に残っているストアを再現し、現行のマイグレーション計画で開けるかを確かめる。
///
/// SwiftData の entity 名は `@Model` クラスの型名（入れ子でも末尾の名前）になる。
/// 公開版のアプリは live model（`GeoMemo` 等）でストアを作っているため、
/// 端末のストアの entity 名は live と同じ名前になっている。
enum LegacyStores {
    /// 1.3.x（Schema V5 相当）: GeoMemo のみ。dwellMinutes まで。
    enum V13 {
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
}

@Suite("実ストアからのマイグレーション", .serialized)
struct MigrationStoreTests {
    private func tempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geomemo-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.store")
    }

    private func openWithPlan(_ url: URL) throws -> ModelContainer {
        let schema = GeoMemoStore.makeSchema()
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: GeoMemoMigrationPlan.self,
                                  configurations: [config])
    }

    @Test("2.0 / 2.0.1 のストア（live model で作成）を現行の計画で開ける")
    func storeFromLiveModelsOpens() throws {
        let url = try tempStoreURL()
        do {
            let schema = GeoMemoStore.makeSchema()
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let ctx = ModelContext(container)
            let memo = GeoMemo(title: "牛乳を買う", note: "", latitude: 35.68, longitude: 139.76, radius: 100)
            ctx.insert(memo)
            try ctx.save()
        }
        let container = try openWithPlan(url)
        let memos = try ModelContext(container).fetch(FetchDescriptor<GeoMemo>())
        #expect(memos.map(\.title) == ["牛乳を買う"])
    }

    @Test("1.3.x のストア（GeoMemo のみ・V5 相当）を現行の計画で開ける")
    func storeFrom13Opens() throws {
        let url = try tempStoreURL()
        do {
            let schema = Schema([LegacyStores.V13.GeoMemo.self])
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let ctx = ModelContext(container)
            let memo = LegacyStores.V13.GeoMemo()
            memo.title = "駅でゴミ出し"
            ctx.insert(memo)
            try ctx.save()
        }
        let container = try openWithPlan(url)
        let memos = try ModelContext(container).fetch(FetchDescriptor<GeoMemo>())
        #expect(memos.map(\.title) == ["駅でゴミ出し"])
    }

    @Test("過去のすべてのスキーマ (V1〜最新) で作ったストアを現行の計画で開ける",
          arguments: GeoMemoMigrationPlan.schemas.map { $0.versionIdentifier.description })
    func everyHistoricalSchemaOpens(version: String) throws {
        let versioned = try #require(GeoMemoMigrationPlan.schemas.first { $0.versionIdentifier.description == version })
        let url = try tempStoreURL()
        do {
            let schema = Schema(versionedSchema: versioned)
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            try ModelContext(container).save()
        }
        _ = try openWithPlan(url)
    }

    /// live model だけを変えて VersionedSchema の追加を忘れると、既存ストアが開けなくなる。
    /// 最新の VersionedSchema と live model が完全に一致していることを、移行なしで開けるかで確かめる。
    @Test("最新の VersionedSchema と live model が一致している")
    func latestSnapshotMatchesLiveModels() throws {
        let latest = try #require(GeoMemoMigrationPlan.schemas.last)
        let url = try tempStoreURL()
        do {
            let schema = Schema(versionedSchema: latest)
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            _ = try ModelContainer(for: schema, configurations: [config])
        }
        let live = GeoMemoStore.makeSchema()
        let config = ModelConfiguration(schema: live, url: url, cloudKitDatabase: .none)
        _ = try ModelContainer(for: live, configurations: [config])   // migrationPlan なし
    }
}

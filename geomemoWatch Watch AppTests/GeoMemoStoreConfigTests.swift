import Testing
import Foundation
import SwiftData
@testable import geomemoWatch_Watch_App

struct GeoMemoStoreConfigTests {
    @Test func 実機かつiCloudサインイン済みならCloudKitを使う() {
        #expect(GeoMemoStoreConfig.shouldUseCloudKit(isSimulator: false, hasICloudAccount: true))
    }

    @Test func iCloud未サインインならCloudKitを使わない() {
        #expect(!GeoMemoStoreConfig.shouldUseCloudKit(isSimulator: false, hasICloudAccount: false))
    }

    @Test func シミュレーターではCloudKitを使わない() {
        #expect(!GeoMemoStoreConfig.shouldUseCloudKit(isSimulator: true, hasICloudAccount: true))
    }

    @Test func コンテナIDとAppGroupIDがiPhoneと同じ() {
        #expect(GeoMemoStoreConfig.cloudKitContainerID == "iCloud.com.yokuro.geomemo")
        #expect(GeoMemoStoreConfig.appGroupID == "group.com.yokuro.geomemo")
    }

    @Test func スキーマが5モデルでiPhoneと同じ() {
        let names = GeoMemoStoreConfig.makeSchema().entities.map(\.name).sorted()
        #expect(names == ["FavoritePlace", "FriendConnection", "GeoMemo", "SharedMemo", "UserProfile"])
    }

    @Test func 移行計画つきでインメモリコンテナを開ける() throws {
        let schema = GeoMemoStoreConfig.makeSchema()
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        _ = try ModelContainer(for: schema, migrationPlan: GeoMemoMigrationPlan.self, configurations: [config])
    }

    @Test func トークンがnilでも前回アカウントが使えていればCloudKitを使う() {
        #expect(GeoMemoStoreConfig.shouldUseCloudKit(isSimulator: false, hasICloudAccount: false, cachedAccountAvailable: true))
        #expect(!GeoMemoStoreConfig.shouldUseCloudKit(isSimulator: true, hasICloudAccount: false, cachedAccountAvailable: true))
    }

    // MARK: 無料版の上限

    @Test func 無料版は上限でメモを作れない() {
        #expect(!MemoLimitPolicy.isAtLimit(currentCount: MemoLimitPolicy.freeMemoLimit - 1, isPro: false))
        #expect(MemoLimitPolicy.isAtLimit(currentCount: MemoLimitPolicy.freeMemoLimit, isPro: false))
        #expect(!MemoLimitPolicy.isAtLimit(currentCount: 100, isPro: true))
    }
}

// MARK: - WatchStoreFactory

struct WatchStoreFactoryTests {
    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("geomemo.store")
    }

    @Test func テストホストでは実ストアを開かずテスト用ステータスになる() {
        let result = WatchStoreFactory.makeContainer(configuration: nil, isTestEnvironment: true)
        #expect(result.status == .testing)
        #expect(result.status.isPersistent)
    }

    @Test func AppGroupが見えなければインメモリにフォールバックする() {
        let result = WatchStoreFactory.makeContainer(configuration: nil, isTestEnvironment: false)
        #expect(result.status == .inMemoryFallback)
        #expect(!result.status.isPersistent)
    }

    @Test func ストアを開けなければインメモリにフォールバックする() throws {
        // 親がファイルになっていて作れない URL
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data().write(to: file)
        let schema = GeoMemoStoreConfig.makeSchema()
        let config = GeoMemoStoreConfig.makeConfiguration(
            schema: schema, url: file.appendingPathComponent("geomemo.store"), useCloudKit: false)
        let result = WatchStoreFactory.makeContainer(schema: schema, configuration: config, isTestEnvironment: false)
        #expect(result.status == .inMemoryFallback)
    }

    @Test func 実ストアを開ければpersistentになる() throws {
        let url = tempStoreURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let schema = GeoMemoStoreConfig.makeSchema()
        let config = GeoMemoStoreConfig.makeConfiguration(schema: schema, url: url, useCloudKit: false)
        let result = WatchStoreFactory.makeContainer(schema: schema, configuration: config, isTestEnvironment: false)
        #expect(result.status == .persistent)
    }

    @Test func 旧Watchストアを5モデルと移行計画で開き直してもメモが残る() throws {
        let url = tempStoreURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 旧 Watch と同じ構成: GeoMemo だけ・移行計画なし・同期なし
        do {
            let oldSchema = Schema([GeoMemo.self])
            let oldConfig = ModelConfiguration(schema: oldSchema, url: url, cloudKitDatabase: .none)
            let oldContainer = try ModelContainer(for: oldSchema, configurations: [oldConfig])
            let context = ModelContext(oldContainer)
            context.insert(GeoMemo(title: "旧Watchのメモ", note: "", latitude: 35.0, longitude: 139.0,
                                   radius: 100, locationName: "場所", colorIndex: 0))
            try context.save()
        }

        let schema = GeoMemoStoreConfig.makeSchema()
        let config = GeoMemoStoreConfig.makeConfiguration(schema: schema, url: url, useCloudKit: false)
        let result = WatchStoreFactory.makeContainer(schema: schema, configuration: config, isTestEnvironment: false)
        #expect(result.status == .persistent)
        let memos = try ModelContext(result.container).fetch(FetchDescriptor<GeoMemo>())
        #expect(memos.map(\.title) == ["旧Watchのメモ"])
    }
}

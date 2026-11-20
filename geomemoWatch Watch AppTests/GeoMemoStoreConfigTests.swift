import Testing
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
}

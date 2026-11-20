import Foundation
import SwiftData

/// iPhone 本体・App Intents・Apple Watch が共有する SwiftData ストアの構成。
///
/// iPhone と Watch は別の端末なので App Group のストアは共有されない。
/// 両方が同じ CloudKit コンテナ（プライベート DB）を同じスキーマ・同じ移行計画で開くことで
/// メモが同期される。スキーマの定義をここ 1 か所に集約し、食い違いを防ぐ。
enum GeoMemoStoreConfig {
    nonisolated static let appGroupID          = "group.com.yokuro.geomemo"
    nonisolated static let cloudKitContainerID = "iCloud.com.yokuro.geomemo"

    /// 全ターゲット共通のスキーマ。ここを変えると CloudKit のスキーマも変わるので
    /// モデルの追加・変更は docs/adr/0001 の手順（VersionedSchema 追加）に従うこと。
    nonisolated static func makeSchema() -> Schema {
        Schema([
            GeoMemo.self,
            FavoritePlace.self,
            UserProfile.self,
            FriendConnection.self,
            SharedMemo.self
        ])
    }

    /// CloudKit 同期を使うか。シミュレーターと、iCloud 未サインイン（トークンなし）のときは使わない。
    nonisolated static func shouldUseCloudKit(isSimulator: Bool, hasICloudAccount: Bool) -> Bool {
        !isSimulator && hasICloudAccount
    }

    nonisolated static var currentEnvironmentUsesCloudKit: Bool {
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        return shouldUseCloudKit(
            isSimulator: isSimulator,
            hasICloudAccount: FileManager.default.ubiquityIdentityToken != nil
        )
    }

    /// App Group 上の `geomemo.store` を開く構成。App Group が見えなければ nil。
    nonisolated static func makeConfiguration(schema: Schema) -> ModelConfiguration? {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("geomemo.store") else { return nil }
        return ModelConfiguration(
            schema: schema,
            url: url,
            cloudKitDatabase: currentEnvironmentUsesCloudKit ? .private(cloudKitContainerID) : .none
        )
    }
}

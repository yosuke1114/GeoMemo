import Foundation
import SwiftData
import os

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
    /// `cachedAccountAvailable` は Watch 用。watchOS では `ubiquityIdentityToken` が当てにならない
    /// 可能性があるため、前回起動で `CKContainer.accountStatus` が `.available` だったかも合わせて見る。
    nonisolated static func shouldUseCloudKit(
        isSimulator: Bool,
        hasICloudAccount: Bool,
        cachedAccountAvailable: Bool = false
    ) -> Bool {
        !isSimulator && (hasICloudAccount || cachedAccountAvailable)
    }

    /// Watch が前回起動で確かめた iCloud アカウントの状態を覚えておくキー（App Group の UserDefaults）。
    nonisolated static let accountAvailableCacheKey = "watchCloudKitAccountAvailable"

    nonisolated static var cachedAccountAvailable: Bool {
        UserDefaults(suiteName: appGroupID)?.bool(forKey: accountAvailableCacheKey) ?? false
    }

    nonisolated static func cacheAccountAvailable(_ available: Bool) {
        UserDefaults(suiteName: appGroupID)?.set(available, forKey: accountAvailableCacheKey)
    }

    nonisolated static var currentEnvironmentUsesCloudKit: Bool {
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        #if os(watchOS)
        let cached = cachedAccountAvailable
        #else
        let cached = false
        #endif
        return shouldUseCloudKit(
            isSimulator: isSimulator,
            hasICloudAccount: FileManager.default.ubiquityIdentityToken != nil,
            cachedAccountAvailable: cached
        )
    }

    private nonisolated static let logger = Logger(subsystem: "com.yokuro.geomemo", category: "StoreConfig")

    /// App Group 上の `geomemo.store` を開く構成。App Group が見えなければ nil。
    /// 選んだモード（CloudKit か local か）を 1 行ログに出す（定数のみ・個人情報なし）。
    nonisolated static func makeConfiguration(schema: Schema) -> ModelConfiguration? {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("geomemo.store") else {
            logger.error("store mode: unavailable (no app group container)")
            return nil
        }
        let useCloudKit = currentEnvironmentUsesCloudKit
        let token = FileManager.default.ubiquityIdentityToken != nil
        logger.notice("store mode: \(useCloudKit ? "cloudkit" : "local", privacy: .public) (ubiquityToken: \(token, privacy: .public))")
        return makeConfiguration(schema: schema, url: url, useCloudKit: useCloudKit)
    }

    /// URL と同期の有無を指定して構成を作る（テスト・フォールバック用）。
    nonisolated static func makeConfiguration(schema: Schema, url: URL, useCloudKit: Bool) -> ModelConfiguration {
        ModelConfiguration(
            schema: schema,
            url: url,
            cloudKitDatabase: useCloudKit ? .private(cloudKitContainerID) : .none
        )
    }
}

import SwiftUI
import SwiftData
import CloudKit
import os

/// Watch のデータの保存状態。
enum WatchStoreStatus: Equatable {
    /// 実ストア（App Group の `geomemo.store`）を開けた。
    case persistent
    /// 実ストアを開けず、インメモリで動いている。変更は保存されず、再起動で消える。
    case inMemoryFallback
    /// テストホスト。実ストアは開かない。
    case testing

    var isPersistent: Bool { self != .inMemoryFallback }
}

private struct WatchStoreStatusKey: EnvironmentKey {
    static let defaultValue: WatchStoreStatus = .persistent
}

extension EnvironmentValues {
    var watchStoreStatus: WatchStoreStatus {
        get { self[WatchStoreStatusKey.self] }
        set { self[WatchStoreStatusKey.self] = newValue }
    }
}

nonisolated enum WatchStoreFactory {
    private static let logger = Logger(subsystem: "com.yokuro.geomemo", category: "WatchStore")

    /// `configuration` が nil（App Group が見えない）や開けないときはインメモリにフォールバックする。
    /// `isTestEnvironment` のときは実ストアを開かない（CloudKit・データ汚染を避ける）。
    static func makeContainer(
        schema: Schema = GeoMemoStoreConfig.makeSchema(),
        configuration: ModelConfiguration?,
        isTestEnvironment: Bool
    ) -> (container: ModelContainer, status: WatchStoreStatus) {
        if isTestEnvironment {
            return (inMemory(schema), .testing)
        }
        if let configuration {
            do {
                let container = try ModelContainer(
                    for: schema,
                    migrationPlan: GeoMemoMigrationPlan.self,
                    configurations: [configuration]
                )
                return (container, .persistent)
            } catch {
                logger.error("ModelContainer failed, falling back to in-memory: \(String(describing: error), privacy: .public)")
            }
        }
        return (inMemory(schema), .inMemoryFallback)
    }

    private static func inMemory(_ schema: Schema) -> ModelContainer {
        // 明示的に同期なし（CloudKit に空のストアを同期させない）
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create in-memory ModelContainer: \(error)")
        }
    }

    static var isTestEnvironment: Bool {
        Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }

    /// iCloud アカウントの状態を確かめて覚える。起動は遅らせない（起動後に非同期で実行）。
    /// 次回起動の `GeoMemoStoreConfig.shouldUseCloudKit` が、`ubiquityIdentityToken` が nil でも
    /// アカウントが使えていれば CloudKit を選べるようにする。
    static func refreshAccountStatus() {
        Task.detached(priority: .utility) {
            do {
                let status = try await CKContainer(identifier: GeoMemoStoreConfig.cloudKitContainerID).accountStatus()
                let available = status == .available
                GeoMemoStoreConfig.cacheAccountAvailable(available)
                logger.notice("account status: \(available ? "available" : "unavailable", privacy: .public)")
            } catch {
                logger.error("accountStatus failed")
            }
        }
    }
}

/// 実ストアを開けずインメモリで動いているときの警告。
struct WatchNotSavedBanner: View {
    var body: some View {
        Label("Not saved. Changes will be lost when the app closes.", systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
    }
}

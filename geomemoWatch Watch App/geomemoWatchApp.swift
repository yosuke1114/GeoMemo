import SwiftUI
import SwiftData

@main
struct geomemoWatch_Watch_AppApp: App {
    let modelContainer: ModelContainer

    init() {
        let schema = GeoMemoStoreConfig.makeSchema()
        do {
            // iPhone と同じ App Group 構成・スキーマ・移行計画・CloudKit コンテナ
            // （プライベート DB）を使い、メモを iPhone と同期する。
            if let config = GeoMemoStoreConfig.makeConfiguration(schema: schema) {
                modelContainer = try ModelContainer(
                    for: schema,
                    migrationPlan: GeoMemoMigrationPlan.self,
                    configurations: [config]
                )
            } else {
                modelContainer = try Self.makeInMemoryContainer(schema: schema)
            }
        } catch {
            // 実ストアを開けなくても起動不能にはしない（同期は次回起動で再試行）。
            print("[GeoMemoWatch] ModelContainer failed (\(error)), falling back to in-memory store.")
            do {
                modelContainer = try Self.makeInMemoryContainer(schema: schema)
            } catch {
                fatalError("Failed to create fallback ModelContainer: \(error)")
            }
        }
    }

    private static func makeInMemoryContainer(schema: Schema) throws -> ModelContainer {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
        .modelContainer(modelContainer)
    }
}

struct WatchRootView: View {
    var body: some View {
        TabView {
            WatchMemoListView()

            WatchNearbyView()

            WatchQuickAddView()
        }
        .tabViewStyle(.verticalPage)
    }
}

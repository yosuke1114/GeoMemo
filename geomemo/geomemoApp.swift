//
//  geomemoApp.swift
//  geomemo
//
//  Created by 黒滝洋輔 on 2026/03/26.
//

import SwiftUI
import SwiftData
import AppIntents
import CoreSpotlight

@main
struct geomemoApp: App {
    static let appGroupID      = "group.com.yokuro.geomemo"
    static let cloudKitContainerID = "iCloud.com.yokuro.geomemo"

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([GeoMemo.self])

        // テスト時はインメモリストアを使用（CloudKit タイムアウト・データ汚染を防ぐ）
        // Bundle.allBundles で xctest バンドルを検出（Swift Testing / XCTest 両対応）
        let isTestEnvironment = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
        if isTestEnvironment {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [config])
        }

        let groupContainer = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)

        // App Group が利用できない場合（テスト・シミュレータ等）はインメモリで安全に動作
        guard let groupContainer else {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [config])
        }

        try? FileManager.default.createDirectory(at: groupContainer, withIntermediateDirectories: true)
        let groupURL = groupContainer.appendingPathComponent("geomemo.store")

        #if targetEnvironment(simulator)
        // シミュレーターでは CloudKit を使用しない（テスト実行時のハングを防ぐ）
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            url: groupURL,
            cloudKitDatabase: .none
        )
        #else
        let useCloudKit = FileManager.default.ubiquityIdentityToken != nil
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            url: groupURL,
            cloudKitDatabase: useCloudKit
                ? .private(cloudKitContainerID)
                : .none
        )
        #endif

        do {
            // Migration plan で V1→V2 の軽量マイグレーションを明示指定
            return try ModelContainer(
                for: schema,
                migrationPlan: GeoMemoMigrationPlan.self,
                configurations: [modelConfiguration]
            )
        } catch {
            // スキーマ不一致でストアが開けない場合はインメモリにフォールバック
            // （テスト実行後のシミュレータ残留データなど）
            print("[GeoMemo] ModelContainer failed (\(error)), falling back to in-memory store.")
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [fallback])
        }
    }()

    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.system.rawValue

    // CloudKit 同期監視（シミュレーターでは通知が来ないだけで副作用なし）
    @State private var syncMonitor = CloudSyncMonitor()

    var body: some Scene {
        WindowGroup {
            SplashView()
                .preferredColorScheme(AppearanceMode(rawValue: appearanceMode)?.colorScheme)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .task {
                    GeoMemoShortcuts.updateAppShortcutParameters()
                    Self.indexAllMemosInSpotlight()
                    NotificationManager.registerCategories()
                }
                #if DEBUG
                .onAppear {
                    DemoDataSeeder.seedIfNeeded(context: sharedModelContainer.mainContext)
                }
                #endif
                .environment(syncMonitor)
        }
        .modelContainer(sharedModelContainer)
    }

    // MARK: - Spotlight Indexing

    static func indexAllMemosInSpotlight() {
        Task {
            do {
                let memos = try GeoMemoStore.fetchAll()
                let entities = memos.map { GeoMemoEntity(from: $0) }
                try await CSSearchableIndex.default().indexAppEntities(entities)
            } catch {
                print("Spotlight indexing failed: \(error)")
            }
        }
    }

    // MARK: - Deep Linking

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "geomemo" else { return }

        switch url.host {
        case "memo":
            if let idString = url.pathComponents.dropFirst().first,
               let uuid = UUID(uuidString: idString) {
                NotificationCenter.default.post(name: .openGeoMemo, object: uuid)
            }
        case "favorites":
            NotificationCenter.default.post(name: .showGeoMemoFavorites, object: nil)
        case "search":
            if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value {
                NotificationCenter.default.post(name: .searchGeoMemos, object: query)
            }
        default:
            break
        }
    }
}

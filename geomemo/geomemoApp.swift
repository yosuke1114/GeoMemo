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
    static let appGroupID = "group.com.yokuro.geomemo"

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            GeoMemo.self,
        ])

        let groupContainer = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)

        // Ensure the App Group directory exists
        if let groupContainer {
            try? FileManager.default.createDirectory(at: groupContainer, withIntermediateDirectories: true)
        }

        let groupURL = groupContainer?.appendingPathComponent("geomemo.store")

        let useCloudKit = FileManager.default.ubiquityIdentityToken != nil

        let modelConfiguration: ModelConfiguration
        if let groupURL {
            modelConfiguration = ModelConfiguration(
                schema: schema,
                url: groupURL,
                cloudKitDatabase: useCloudKit ? .automatic : .none
            )
        } else {
            modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: useCloudKit ? .automatic : .none
            )
        }

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // If migration fails, delete the old store and create a new one
            print("Migration failed, recreating model container: \(error)")
            
            // Get the store URL
            let storeURL = modelConfiguration.url
            try? FileManager.default.removeItem(at: storeURL)
            print("Deleted old store at: \(storeURL)")
            
            // Try again with fresh database
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer even after cleanup: \(error)")
            }
        }
    }()

    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.system.rawValue

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
                }
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

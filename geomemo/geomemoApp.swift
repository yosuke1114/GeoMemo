//
//  geomemoApp.swift
//  geomemo
//
//  Created by 黒滝洋輔 on 2026/03/26.
//

import SwiftUI
import SwiftData

@main
struct geomemoApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            GeoMemo.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

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

    var body: some Scene {
        WindowGroup {
            SplashView()
        }
        .modelContainer(sharedModelContainer)
    }
}

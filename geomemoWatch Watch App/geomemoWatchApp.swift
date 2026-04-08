import SwiftUI
import SwiftData

@main
struct geomemoWatch_Watch_AppApp: App {
    let modelContainer: ModelContainer

    init() {
        let schema = Schema([GeoMemo.self])
        let appGroupID = "group.com.yokuro.geomemo"

        if let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("geomemo.store") {
            let config = ModelConfiguration(
                schema: schema,
                url: groupURL,
                cloudKitDatabase: .none
            )
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create ModelContainer: \(error)")
            }
        } else {
            // Fallback: in-memory container for previews
            do {
                let config = ModelConfiguration(isStoredInMemoryOnly: true)
                modelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create fallback ModelContainer: \(error)")
            }
        }
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

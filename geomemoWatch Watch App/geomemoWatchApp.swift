import SwiftUI
import SwiftData

@main
struct geomemoWatch_Watch_AppApp: App {
    let modelContainer: ModelContainer
    let storeStatus: WatchStoreStatus

    init() {
        // iPhone と同じ App Group 構成・スキーマ・移行計画・CloudKit コンテナ（プライベート DB）で
        // 開き、メモを iPhone と同期する。開けなければインメモリで起動し、画面で知らせる。
        let schema = GeoMemoStoreConfig.makeSchema()
        let isTest = WatchStoreFactory.isTestEnvironment
        let result = WatchStoreFactory.makeContainer(
            schema: schema,
            configuration: isTest ? nil : GeoMemoStoreConfig.makeConfiguration(schema: schema),
            isTestEnvironment: isTest
        )
        modelContainer = result.container
        storeStatus = result.status
        if !isTest { WatchStoreFactory.refreshAccountStatus() }
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(\.watchStoreStatus, storeStatus)
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

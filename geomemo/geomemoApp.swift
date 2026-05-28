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
import StoreKit
import CloudKit

// MARK: - CKShare Acceptance Delegate

final class GeoMemoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in
            do {
                try await CKShareService.shared.acceptShare(metadata: metadata)
                // share の所有者をフレンドとして登録（既存なら何もしない）
                let ownerRecordID = metadata.ownerIdentity.userRecordID?.recordName ?? ""
                let ownerName = metadata.ownerIdentity.nameComponents.map {
                    PersonNameComponentsFormatter().string(from: $0)
                } ?? ""
                NotificationCenter.default.post(
                    name: .didAcceptSharedMemo,
                    object: AcceptedShareInfo(
                        ownerRecordID: ownerRecordID,
                        ownerName: ownerName,
                        shareRecordID: metadata.share.recordID
                    )
                )
            } catch {
                ToastCenter.shared.show(.error(
                    String(localized: "共有メモの受諾に失敗しました。通信状況を確認して再度お試しください。")
                ))
            }
        }
    }
}

struct AcceptedShareInfo {
    let ownerRecordID: String
    let ownerName: String
    let shareRecordID: CKRecord.ID
}

extension Notification.Name {
    static let didAcceptSharedMemo = Notification.Name("didAcceptSharedMemo")
}

@main
struct geomemoApp: App {
    @UIApplicationDelegateAdaptor(GeoMemoAppDelegate.self) private var appDelegate

    /// App Group / iCloud container ID は GeoMemoStore に集約されているので
    /// そちらを single source of truth として参照する（旧 `geomemoApp.appGroupID` は廃止）。
    static var appGroupID: String          { GeoMemoStore.appGroupID }
    static var cloudKitContainerID: String { GeoMemoStore.cloudKitContainerID }
    static let isUITesting = CommandLine.arguments.contains("-UITesting")

    var sharedModelContainer: ModelContainer = {
        let schema = GeoMemoStore.makeSchema()

        // テスト時はインメモリストアを使用（CloudKit タイムアウト・データ汚染を防ぐ）
        let isTestEnvironment = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
            || isUITesting
        if isTestEnvironment {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [config])
        }

        // 通常起動は GeoMemoStore.sharedContainer() に委譲。App Group が見えない、
        // あるいは migration が失敗した場合のみインメモリにフォールバック。
        do {
            return try GeoMemoStore.sharedContainer()
        } catch {
            print("[GeoMemo] ModelContainer failed (\(error)), falling back to in-memory store.")
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [fallback])
        }
    }()

    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.system.rawValue

    // CloudKit 同期監視（シミュレーターでは通知が来ないだけで副作用なし）
    @State private var syncMonitor = CloudSyncMonitor()

    // StoreKit: 起動時に Pro ステータスを復元
    private let storeKit = StoreKitManager.shared

    var body: some Scene {
        WindowGroup {
            SplashView()
                .toastOverlay()
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
                    // UITest 中は -seedDemoData フラグがある場合のみシード
                    // （それ以外の UITest では空状態を保証する）
                    let seedRequested = CommandLine.arguments.contains("-seedDemoData")
                    if !Self.isUITesting || seedRequested {
                        DemoDataSeeder.seedIfNeeded(context: sharedModelContainer.mainContext)
                    }
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
                let entities = try GeoMemoStore.fetchAllEntities()
                try await CSSearchableIndex.default().indexAppEntities(entities)
            } catch {
                print("Spotlight indexing failed: \(error)")
            }
        }
    }

    /// 削除されたメモを Spotlight からも除去する。再インデックスでは消えるが、
    /// Apple のインデックスは "なくなった項目を残す" 動作なので明示的に削除が必要。
    static func removeFromSpotlight(memoID: UUID) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [memoID.uuidString]) { error in
            if let error { print("Spotlight delete failed: \(error)") }
        }
    }

    /// メモ削除直後の Spotlight 反映を一括処理。removeFromSpotlight だけだと
    /// 周辺メモの順序情報が古いままになるので reindex も走らせる。
    static func handleMemoDeleted(id: UUID) {
        removeFromSpotlight(memoID: id)
        indexAllMemosInSpotlight()
    }

    // MARK: - Deep Linking

    /// Deep-link URL の scheme / host 定数。widget 側 (`geomemoWidget.swift`) で URL を
    /// 組み立てる際にも同じ scheme を使うのでドリフトに注意。
    static let deepLinkScheme = "geomemo"
    enum DeepLinkHost {
        static let memo = "memo"
        static let favorites = "favorites"
        static let search = "search"
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == Self.deepLinkScheme else { return }

        switch url.host {
        case DeepLinkHost.memo:
            if let idString = url.pathComponents.dropFirst().first,
               let uuid = UUID(uuidString: idString) {
                NotificationCenter.default.post(name: .openGeoMemo, object: uuid)
            }
        case DeepLinkHost.favorites:
            NotificationCenter.default.post(name: .showGeoMemoFavorites, object: nil)
        case DeepLinkHost.search:
            if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value {
                NotificationCenter.default.post(name: .searchGeoMemos, object: query)
            }
        default:
            break
        }
    }
}

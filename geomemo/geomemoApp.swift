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
import os

// MARK: - CKShare Acceptance Delegate

final class GeoMemoAppDelegate: NSObject, UIApplicationDelegate {
    /// CloudKit の購読通知（依頼の到着・完了）を受け取るために APNs へ登録する。
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    /// 旧版の購読（-v1）の通知を受けたら、その購読を消す。同じ Apple ID の旧版の端末が起動のたびに
    /// 作り直すため、起動時の確認だけでは消えている時間が短い（docs/sharing.md の制限事項）。
    /// -v1 は `shouldSendContentAvailable` 付きなので、バックグラウンドでもここが呼ばれる。
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let ckNotification = CKNotification(fromRemoteNotificationDictionary: userInfo)
        guard RequesterSubscriptionPolicy.isLegacy(ckNotification?.subscriptionID) else {
            completionHandler(.noData)
            return
        }
        Task {
            do {
                try await CKShareService.shared.ensureRequesterSubscriptions()
                completionHandler(.newData)
            } catch {
                completionHandler(.failed)
            }
        }
    }

    /// `application(_:userDidAcceptCloudKitShareWith:)` は iOS 26 で deprecated（UIScene ライフサイクルへ移行）。
    /// SwiftUI の WindowGroup に scene delegate を差し込み、共有受諾を scene 側で受け取る。
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = GeoMemoSceneDelegate.self
        return configuration
    }

    /// CKShare 受諾の共通処理（起動中 / コールドスタートの両経路から呼ばれる）。
    static func acceptCloudKitShare(_ metadata: CKShare.Metadata) {
        Task { @MainActor in
            // 受諾の通信中も「届いている」と数える（初回起動のオンボーディングに、依頼が届いていることを出すため）
            PendingShareQueue.shared.beginIncoming()
            ToastCenter.shared.show(.info(String(localized: "Getting the request…"), duration: 2))
            do {
                try await CKShareService.shared.acceptShare(metadata: metadata)
                // share の所有者をフレンドとして登録（既存なら何もしない）
                let ownerRecordID = metadata.ownerIdentity.userRecordID?.recordName ?? ""
                let ownerName = metadata.ownerIdentity.nameComponents.map {
                    PersonNameComponentsFormatter().string(from: $0)
                } ?? ""
                // 先にキューへ積み、通知は「処理して」の合図にする。ContentView が表示中なら
                // すぐ取り出され、未表示なら表示されたときに取り出される。
                PendingShareQueue.shared.enqueue(AcceptedShareInfo(
                    ownerRecordID: ownerRecordID,
                    ownerName: ownerName,
                    shareRecordID: metadata.share.recordID,
                    rootRecordName: metadata.hierarchicalRootRecordID?.recordName
                ))
                NotificationCenter.default.post(name: .didAcceptSharedMemo, object: nil)
            } catch {
                PendingShareQueue.shared.failIncoming()
                // CKError のコードで分類する。分からないものは汎用の文にする（原因を決め打ちしない）。
                let failure = ShareAcceptFailure.classify(error: error)
                // エラーの説明文には名前などが入りうるので private。コードだけ public にする
                let code = (error as? CKError)?.code.rawValue ?? -1
                CKShareService.logger.error("accept share failed: code \(code, privacy: .public) \(error.localizedDescription, privacy: .private)")
                let message = failure.message
                ToastCenter.shared.show(.error(message, duration: 5))
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }
}

extension ShareAcceptFailure {
    /// 受諾に失敗したときに出す文。
    nonisolated var message: String {
        switch self {
        case .notSignedIn:
            return String(localized: "Sign in to iCloud, then open the link again.")
        case .network:
            return String(localized: "Couldn't connect. Open the link again when you're online.")
        case .goneOrCancelled:
            return String(localized: "This request was canceled or no longer exists.")
        case .notInvited:
            return String(localized: "Only the invited person can open this link.")
        case .needsVerification:
            return String(localized: "Check that you're signed in to iCloud with the email address or phone number that was invited.")
        case .other:
            return String(localized: "共有メモの受諾に失敗しました。通信状況を確認して再度お試しください。")
        }
    }
}

/// SwiftUI の WindowGroup 用 scene delegate。CKShare の受諾のみを扱う
/// （ウインドウ生成やサイズ変化は SwiftUI 側に任せる）。
final class GeoMemoSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// アプリ未起動時に共有リンクから起動されたケース。
    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            GeoMemoAppDelegate.acceptCloudKitShare(metadata)
        }
    }

    /// 起動中に共有リンクを受諾したケース。
    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        GeoMemoAppDelegate.acceptCloudKitShare(cloudKitShareMetadata)
    }
}

struct AcceptedShareInfo {
    let ownerRecordID: String
    let ownerName: String
    let shareRecordID: CKRecord.ID
    /// 共有のルートのレコード名（`SharedMemo.ckRecordName` と一致する想定）。取れなかったときは nil。
    var rootRecordName: String? = nil

    var key: AcceptedShareKey { AcceptedShareKey(rootRecordName: rootRecordName, ownerRecordID: ownerRecordID) }
}

/// 受諾した共有の保留キュー。コールドスタートの受諾は、ContentView が表示される前
/// （オンボーディング中など）に起きて、通知を受ける側がいない。ここに積んでおき、
/// ContentView が表示されたとき・通知を受けたときに取り出して処理する。
@MainActor @Observable
final class PendingShareQueue {
    static let shared = PendingShareQueue()

    private var items: [AcceptedShareInfo] = []

    /// 受諾の通信中と、積まれたまま未処理の数。オンボーディングに「依頼が届いています」を出す判断に使う。
    private(set) var incomingCount = 0

    /// 受諾を始めた（通信中）。
    func beginIncoming() { incomingCount += 1 }

    /// 受諾に失敗した。
    func failIncoming() { incomingCount = max(0, incomingCount - 1) }

    /// 受諾に成功して積む（`beginIncoming` で数えた 1 件が、積まれた 1 件になる）。
    func enqueue(_ info: AcceptedShareInfo) { items.append(info) }

    /// 積まれているものを順に取り出す（取り出したら空になる）。
    func drain() -> [AcceptedShareInfo] {
        defer {
            incomingCount = max(0, incomingCount - items.count)
            items.removeAll()
        }
        return items
    }
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
                        DemoDataSeeder.seedReceivedIfNeeded(context: sharedModelContainer.mainContext)
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

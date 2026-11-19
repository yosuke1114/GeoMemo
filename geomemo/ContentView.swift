import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import CloudKit
// Phosphor icons loaded from local Assets.xcassets

// Brand colors and Color(hex:) are defined in Theme.swift

// MARK: - Main Content View
struct ContentView: View {
    @Query(sort: \GeoMemo.createdAt, order: .reverse) private var memos: [GeoMemo]
    @Query(sort: \SharedMemo.createdAt, order: .reverse) private var allSharedMemos: [SharedMemo]
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \FriendConnection.createdAt) private var friends: [FriendConnection]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// 折りたたみ iPhone の展開時 / iPad / 横向き大画面では `.regular` になる。
    /// 端末種別ではなくサイズクラスで判定し、ウインドウサイズ変化にライブ追従させる。
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showList = false
    @State private var showSettings = false
    @State private var isSearching = false
    @State private var deepLinkMemoID: UUID?
    @State private var intentShowFavorites = false
    @State private var showWatchDashboard = false

    /// ルートの現在幅。折りたたみ/展開やウインドウリサイズのたびに更新される。
    @State private var containerWidth: CGFloat = 0

    /// regular 幅（展開時）はマップとリストを左右 2 ペインで並べる。
    private var isSideBySide: Bool { horizontalSizeClass == .regular }

    /// 2 ペイン時のリスト幅（ウインドウ幅の 40% を 320〜440pt にクランプ）。
    private var listPaneWidth: CGFloat {
        min(max(containerWidth * 0.4, 320), 440)
    }

    /// ZStack ⇄ HStack を `AnyLayout` で切り替えることで、サイズクラスが変わっても
    /// 子ビュー（MapTabView / ListTabView）の identity と @State（カメラ位置・検索・シート等）を保つ。
    private var rootLayout: AnyLayout {
        isSideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(ZStackLayout())
    }

    var body: some View {
        rootLayout {
            // マップは常に描画しておく（compact: 背景 / regular: 左ペイン）
            VStack(spacing: 0) {
                CustomNavigationBar(memoCount: memos.count, showSettings: $showSettings, isSearching: $isSearching, showWatchDashboard: $showWatchDashboard)
                MapTabView(memos: memos, isSearching: $isSearching, deepLinkMemoID: $deepLinkMemoID, showList: $showList)
            }
            .background(Brand.background)
            .ignoresSafeArea(edges: .bottom)

            // リスト画面（compact: 右からスライドインして全面を覆う / regular: 右ペイン）
            if showList {
                ListTabView(
                    memos: memos,
                    intentShowFavorites: $intentShowFavorites,
                    showList: $showList,
                    showSettings: $showSettings
                )
                // regular 幅ではウインドウ幅に応じた可変ペイン幅、compact では nil（従来どおり全面）。
                .frame(width: isSideBySide ? listPaneWidth : nil)
                .overlay(alignment: .leading) {
                    if isSideBySide {
                        Rectangle().fill(Brand.border).frame(width: 1).ignoresSafeArea()
                    }
                }
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showList)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            containerWidth = newWidth
        }
        .fullScreenCover(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGeoMemo)) { notification in
            if let id = notification.object as? UUID {
                // 2 ペイン時はマップが常に見えているのでリストは閉じない。
                if !isSideBySide { showList = false }
                deepLinkMemoID = id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGeoMemoFavorites)) { _ in
            showList = true
            intentShowFavorites = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchGeoMemos)) { _ in
            if !isSideBySide { showList = false }
            isSearching = true
        }
        .sheet(isPresented: $showWatchDashboard) {
            WatchDashboardView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    async let drain: () = PendingEventQueue.shared.drain()
                    async let sync:  () = syncSharedMemos()
                    async let subs:  () = ensureRequesterSubscriptionsOnce()
                    _ = await (drain, sync, subs)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didEnterSharedMemoRegion)) { notification in
            if let identifier = notification.object as? String {
                Task { await handleSharedMemoFired(geofenceIdentifier: identifier) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didAcceptSharedMemo)) { notification in
            if let info = notification.object as? AcceptedShareInfo {
                registerFriendIfNeeded(info: info)
                Task { await syncSharedMemos() }
            }
        }
    }

    // MARK: - Friend Auto-Registration

    /// CKShare 受諾時に、share 所有者を FriendConnection として登録（既存ならスキップ）。
    /// `@Query` snapshot ではなく FetchDescriptor で直近の永続状態を見ることで、
    /// 連続 .didAcceptSharedMemo 受信時の二重挿入レースを防ぐ。
    private func registerFriendIfNeeded(info: AcceptedShareInfo) {
        if FriendConnection.registerIfNeeded(recordID: info.ownerRecordID, displayName: info.ownerName, in: modelContext) {
            try? modelContext.save()
        }
    }

    // MARK: - Sync Received SharedMemos

    @State private var isSyncing = false

    /// 依頼者向け通知の購読を、起動ごとに 1 回だけ確認・登録する。
    @MainActor private static var didEnsureSubscriptions = false
    private func ensureRequesterSubscriptionsOnce() async {
        guard !Self.didEnsureSubscriptions, profiles.first != nil else { return }
        do {
            try await CKShareService.shared.ensureRequesterSubscriptions()
            Self.didEnsureSubscriptions = true
        } catch {
            // iCloud 未サインインや通信不可。次回のアクティブ化で再試行する。
            print("[GeoMemo] requester subscription failed: \(error)")
        }
    }

    private func syncSharedMemos() async {
        guard !isSyncing, profiles.first != nil else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let received = try await CKShareService.shared.fetchReceivedSharedMemos()
            var didChange = false
            for data in received {
                let recordName = data.ckRecordID.recordName
                SharedMemoNoteStore.setNote(data.memoNote, for: recordName)
                let zoneOwner = data.ckRecordID.zoneID.ownerName
                if let existing = allSharedMemos.first(where: { $0.ckRecordName == recordName }) {
                    if existing.requesterRecordID.isEmpty && !zoneOwner.isEmpty {
                        existing.requesterRecordID = zoneOwner
                        didChange = true
                    }
                    if existing.apply(data) {
                        didChange = true
                        // 取り消し・完了になった依頼は位置の監視をやめる
                        if !existing.isActive {
                            LocationManager.shared.stopMonitoring(memoID: existing.geofenceIdentifier)
                        }
                    }
                    // 「リンクで送る」の依頼は受信者が未定。自分の名前を書き込み、依頼者側に表示させる
                    if data.recipientRecordID.isEmpty, let me = profiles.first, !me.iCloudRecordID.isEmpty {
                        existing.recipientRecordID = me.iCloudRecordID
                        existing.recipientName = me.displayName
                        didChange = true
                        let recordID = data.ckRecordID
                        Task {
                            try? await CKShareService.shared.claimRecipient(
                                recordID: recordID, name: me.displayName, userRecordName: me.iCloudRecordID)
                        }
                    }
                } else if data.status == .cancelled {
                    // まだ取り込んでいない依頼が既に取り消されていれば取り込まない
                    continue
                } else {
                    let shared = SharedMemo(
                        ckRecordName:        recordName,
                        memoTitle:           data.memoTitle,
                        memoLocationName:    data.memoLocationName,
                        memoLatitude:        data.memoLatitude,
                        memoLongitude:       data.memoLongitude,
                        memoRadius:          data.memoRadius,
                        memoDeadline:        data.memoDeadline,
                        memoTimeWindowStart: data.memoTimeWindowStart,
                        memoTimeWindowEnd:   data.memoTimeWindowEnd,
                        // CKShare の sharedDB ゾーンオーナー名 = 依頼者の userRecordID。
                        // sharedDB への書き戻し時に CKRecord.ID(zoneID:) の ownerName で必要なため永続化する。
                        requesterRecordID:   zoneOwner,
                        requesterName:       data.requesterName,
                        recipientRecordID:   data.recipientRecordID,
                        recipientName:       data.recipientName,
                        autoComplete:        data.autoComplete,
                        isMyRequest:         false
                    )
                    modelContext.insert(shared)
                    didChange = true
                    if data.status == .active {
                        let region = CLCircularRegion(
                            center: shared.coordinate,
                            radius: max(50, shared.memoRadius),
                            identifier: shared.geofenceIdentifier
                        )
                        region.notifyOnEntry = true
                        LocationManager.shared.startMonitoring(region: region)
                    }
                }
            }
            if didChange { try? modelContext.save() }
        } catch {
            // ネットワーク不可は通常運用の一部なので、UI を遮るのは "今ユーザー操作で
            // 取得を期待していたとき" だけにする。ここはバックグラウンド同期なので silent。
        }
    }

    // MARK: - Handle Shared Memo Geofence Fire

    private func handleSharedMemoFired(geofenceIdentifier: String) async {
        guard let shared = allSharedMemos.first(where: { $0.geofenceIdentifier == geofenceIdentifier }) else { return }
        let now = Date()
        shared.firedAt = now

        // autoComplete なら fired を飛ばして completed を一度だけ書き込む
        let finalStatus: ShareStatus = shared.autoComplete ? .completed : .fired
        shared.status = finalStatus
        if shared.autoComplete { shared.completedAt = now }

        do {
            try await CKShareService.shared.updateStatus(recordID: shared.cloudKitRecordID, status: finalStatus, date: now)
        } catch {
            let owner = shared.zoneOwnerName
            let event: PendingShareEvent = shared.autoComplete
                ? .completed(ckRecordName: shared.ckRecordName, zoneOwnerName: owner, completedAt: now)
                : .fired(ckRecordName: shared.ckRecordName, zoneOwnerName: owner, firedAt: now)
            PendingEventQueue.shared.enqueue(event)
        }

        await NotificationManager.shared.scheduleSharedMemoFiredNotification(
            memoTitle:     shared.memoTitle,
            requesterName: shared.requesterName,
            sharedID:      shared.id.uuidString
        )

        LocationManager.shared.stopMonitoring(memoID: geofenceIdentifier)
        try? modelContext.save()
    }
}

// MARK: - Preview
#Preview {
    ContentView()
        .modelContainer(for: GeoMemo.self, inMemory: true)
}


/// 受信した依頼を削除する。位置監視と本文キャッシュを消し、ローカルから削除したうえで
/// CloudKit の共有から抜ける (抜けないと次回同期で再取り込みされる)。
@MainActor
func deleteReceivedSharedMemo(_ shared: SharedMemo, in context: ModelContext) {
    let recordID = shared.cloudKitRecordID
    LocationManager.shared.stopMonitoring(memoID: shared.geofenceIdentifier)
    SharedMemoNoteStore.setNote("", for: shared.ckRecordName)
    context.delete(shared)
    try? context.save()
    Task {
        do {
            try await CKShareService.shared.leaveReceivedShare(recordID: recordID)
        } catch {
            ToastCenter.shared.show(.error(
                String(localized: "共有の解除に失敗しました。通信状況を確認してください。")
            ))
        }
    }
}

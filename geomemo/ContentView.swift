import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import CloudKit
import os
// Phosphor icons loaded from local Assets.xcassets

// Brand colors and Color(hex:) are defined in Theme.swift

// MARK: - Main Content View
struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .transition(reduceMotion ? .opacity : .move(edge: .trailing))
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
                    async let unsent: () = cleanUpUnsentShares()
                    _ = await (drain, sync, subs, unsent)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didEnterSharedMemoRegion)) { notification in
            if let identifier = notification.object as? String {
                Task { await handleSharedMemoFired(geofenceIdentifier: identifier) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didAcceptSharedMemo)) { _ in
            processPendingShares()
            Task { await syncSharedMemos() }
        }
        // 表示されたとき: 表示前に受諾した共有（共有リンクからの初回起動など）を処理し、一度同期する。
        // scenePhase の変化を待たない（初回起動では .active への変化が起きないことがある）。
        .task {
            processPendingShares()
            await syncSharedMemos()
        }
    }

    /// 保留キューにある受諾済みの共有をフレンド登録する。
    private func processPendingShares() {
        for info in PendingShareQueue.shared.drain() {
            registerFriendIfNeeded(info: info)
        }
    }

    // MARK: - Friend Auto-Registration

    /// CKShare 受諾時に、share 所有者を FriendConnection として登録（既存ならスキップ）。
    /// `@Query` snapshot ではなく FetchDescriptor で直近の永続状態を見ることで、
    /// 連続 .didAcceptSharedMemo 受信時の二重挿入レースを防ぐ。
    /// 所有者は CloudKit の共有情報 (`CKShare.Metadata.ownerIdentity`) から取るので本人確認済み。
    /// 共有の受諾はユーザー自身の操作なので、以前に削除したフレンドでも登録し直す（削除の記録も消す）。
    /// 既に登録済みのフレンドは、CloudKit の名前が分かればそれに合わせて「確認済み」にする。
    private func registerFriendIfNeeded(info: AcceptedShareInfo) {
        FriendTombstoneStore.shared.remove(info.ownerRecordID)
        let verified = VerifiedFriendStore.shared
        var changed = FriendConnection.registerIfNeeded(recordID: info.ownerRecordID, displayName: info.ownerName,
                                                        in: modelContext, verified: verified)
        if FriendConnection.confirmIdentity(recordID: info.ownerRecordID, cloudKitName: info.ownerName,
                                            in: modelContext, verified: verified) {
            changed = true
        }
        if changed { try? modelContext.save() }
    }

    // MARK: - Sync Received SharedMemos

    @State private var isSyncing = false

    /// 依頼者向け通知の購読を、起動ごとに 1 回だけ確認・登録する（旧版の購読 -v1 もここで消す）。
    /// 全項目が成功したときだけ済みにする。一部でも失敗したら、次回のアクティブ化で再試行する。
    /// 起動後に旧版の端末が -v1 を作り直した場合は、-v1 の通知を受けたときに消す（`NotificationManager`、
    /// `GeoMemoAppDelegate`）。
    @MainActor private static var didEnsureSubscriptions = false
    private func ensureRequesterSubscriptionsOnce() async {
        guard !Self.didEnsureSubscriptions, profiles.first != nil else { return }
        do {
            try await CKShareService.shared.ensureRequesterSubscriptions()
            Self.didEnsureSubscriptions = true
        } catch {
            // iCloud 未サインインや通信不可、一部の購読の保存・削除の失敗。次回のアクティブ化で再試行する。
            CKShareService.logger.error("requester subscription failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 送らなかった依頼の後片付け

    @MainActor private static var isCleaningUnsentShares = false

    /// 送らずに閉じたのに消せなかった依頼や、共有シートの表示中にアプリが終了された依頼を片付ける。
    /// 相手に届いているかもしれない依頼（参加者がいる）は消さず、ローカルに「未送信」として残す。
    private func cleanUpUnsentShares() async {
        let store = UnsentShareStore.shared
        let now = Date()
        let actionable = store.entries.contains {
            UnsentShareCleanupPolicy.action(for: $0, now: now) != .leave
        }
        guard actionable, !Self.isCleaningUnsentShares, let me = profiles.first else { return }
        Self.isCleaningUnsentShares = true
        defer { Self.isCleaningUnsentShares = false }

        let adopted = await CKShareService.shared.cleanUpUnsentShares(store: store, now: now)
        guard !adopted.isEmpty else { return }
        for (entry, data) in adopted {
            let recordName = data.ckRecordID.recordName
            guard !allSharedMemos.contains(where: { $0.ckRecordName == recordName }) else { continue }
            let friendName = friends.first { $0.friendRecordID == entry.invitedFriendRecordName }?.friendDisplayName
            modelContext.insert(SharedMemo(
                ckRecordName:        recordName,
                memoTitle:           data.memoTitle,
                memoLocationName:    data.memoLocationName,
                memoLatitude:        data.memoLatitude,
                memoLongitude:       data.memoLongitude,
                memoRadius:          data.memoRadius,
                memoDeadline:        data.memoDeadline,
                memoTimeWindowStart: data.memoTimeWindowStart,
                memoTimeWindowEnd:   data.memoTimeWindowEnd,
                requesterRecordID:   me.iCloudRecordID,
                requesterName:       me.displayName,
                // 受信者は、相手が書けるレコードの値ではなく、自分で加えたフレンドか（招待なら）未定にする
                recipientRecordID:   entry.invitedFriendRecordName,
                recipientName:       friendName ?? String(localized: "リンクで共有"),
                autoComplete:        data.autoComplete,
                isMyRequest:         true,
                // 送信日時は端末の記録を使う（フレンドの再登録の判定に使うため、相手が書ける値は使わない）
                createdAt:           entry.createdAt,
                status:              data.status,
                firedAt:             data.firedAt,
                completedAt:         data.completedAt
            ))
            SharedMemoNoteStore.setNote(data.memoNote, for: recordName)
        }
        try? modelContext.save()
    }

    private func syncSharedMemos() async {
        // プロフィール（表示名）が無くても取り込む。受信者としての名前の書き込みだけ、プロフィールがあるときに行う
        guard !isSyncing else { return }
        let me = profiles.first
        isSyncing = true
        defer { isSyncing = false }
        do {
            let received = try await CKShareService.shared.fetchReceivedSharedMemos()
            var didChange = false
            for data in received {
                let recordName = data.ckRecordID.recordName
                // 完了・取り消しになった依頼の本文は端末に残さない（完了直後は読めるよう少しだけ残す）
                let keepsNote = SharedMemoNotePolicy.retainsReceivedNote(
                    status: data.status, completedAt: data.completedAt, now: Date())
                SharedMemoNoteStore.setNote(keepsNote ? data.memoNote : "", for: recordName)
                let zoneOwner = data.ckRecordID.zoneID.ownerName
                // 招待で送られた依頼は受信者が未定。監視中なら自分の名前を書き込み、依頼者側に表示させる。
                // 依頼者側はこの値を共有の参加者と突き合わせてから使う。到着・完了後は書き込まない
                // （更新が依頼者への通知を再び出すため）。初回の取り込みでも書き込む。
                let shouldClaim = SharedImportPolicy.shouldClaim(
                    recipientRecordID: data.recipientRecordID, status: data.status,
                    myICloudRecordID: me?.iCloudRecordID)
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
                    if shouldClaim, let me {
                        existing.recipientRecordID = me.iCloudRecordID
                        existing.recipientName = me.displayName
                        didChange = true
                        claimRecipient(data.ckRecordID, me: me)
                    }
                } else if data.status == .cancelled {
                    // まだ取り込んでいない依頼が既に取り消されていれば取り込まない
                    continue
                } else {
                    let claimingMe = shouldClaim ? me : nil
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
                        recipientRecordID:   claimingMe?.iCloudRecordID ?? data.recipientRecordID,
                        recipientName:       claimingMe?.displayName ?? data.recipientName,
                        autoComplete:        data.autoComplete,
                        isMyRequest:         false,
                        status:              data.status,
                        firedAt:             data.firedAt,
                        completedAt:         data.completedAt
                    )
                    modelContext.insert(shared)
                    didChange = true
                    if let claimingMe {
                        claimRecipient(data.ckRecordID, me: claimingMe)
                    }
                    if data.status == .active {
                        LocationManager.shared.startMonitoring(region: shared.monitoringRegion)
                    }
                }
            }
            if didChange { try? modelContext.save() }
        } catch {
            // ネットワーク不可は通常運用の一部なので、UI を遮るのは "今ユーザー操作で
            // 取得を期待していたとき" だけにする。ここはバックグラウンド同期なので silent。
        }
    }

    private func claimRecipient(_ recordID: CKRecord.ID, me: UserProfile) {
        let name = me.displayName
        let userRecordName = me.iCloudRecordID
        Task {
            try? await CKShareService.shared.claimRecipient(
                recordID: recordID, name: name, userRecordName: userRecordName)
        }
    }

    // MARK: - Handle Shared Memo Geofence Fire

    private func handleSharedMemoFired(geofenceIdentifier: String) async {
        guard let shared = allSharedMemos.first(where: { $0.geofenceIdentifier == geofenceIdentifier }) else { return }
        // 監視中の依頼だけを発火させる。到着済み・完了・取り消し後の再進入で状態を書き直すと、
        // 依頼者へ「到着」通知が重ねて届く。
        guard shared.status == .active else {
            LocationManager.shared.stopMonitoring(memoID: geofenceIdentifier)
            return
        }
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

/// 受信した依頼を完了にする (リスト行・詳細画面で共通)。
/// 位置監視を止め、依頼者へ完了を送る。送れなければ未送信キューに積む。
@MainActor
func completeReceivedSharedMemo(_ shared: SharedMemo, in context: ModelContext) {
    let now = Date()
    shared.status      = .completed
    shared.completedAt = now
    LocationManager.shared.stopMonitoring(memoID: shared.geofenceIdentifier)
    try? context.save()
    let recordID = shared.cloudKitRecordID
    let owner = shared.zoneOwnerName
    let recordName = shared.ckRecordName
    Task {
        do {
            try await CKShareService.shared.updateStatus(recordID: recordID, status: .completed, date: now)
        } catch {
            PendingEventQueue.shared.enqueue(
                .completed(ckRecordName: recordName, zoneOwnerName: owner, completedAt: now)
            )
        }
    }
}

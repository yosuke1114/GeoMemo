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
    /// 受諾した共有に対して今出すもの（受け取り画面・一覧・通常の詳細）。`MapTabView` が出せるときに出す。
    @State private var arrival: ArrivalPresentation?
    /// 受諾したが、まだ何を出すか決めていない共有。
    @State private var awaitingArrivals: [AcceptedShareInfo] = []
    @State private var isResolvingArrival = false
    /// 同期で新しく取り込んだ依頼・取り消し済みで取り込まなかった依頼（受諾との突き合わせに使う）。
    @State private var newlyInserted: Set<String> = []
    @State private var skippedCancelled: [String: String] = [:]
    /// そのうち、受諾の後に初めて見つけたもの（ルートのレコード名が取れなかったときの保険の判定に使う）。
    @State private var freshCancelled: Set<String> = []

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
                MapTabView(memos: memos, isSearching: $isSearching, deepLinkMemoID: $deepLinkMemoID, showList: $showList,
                           arrival: arrivalBinding)
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
        .onReceive(NotificationCenter.default.publisher(for: .startNewGeoMemo)) { _ in
            // 新しいメモは地図から始めるので、リストを開いていれば閉じる
            if !isSideBySide { showList = false }
        }
        // 設定・見守りを開いている間は、新しいメモの要求を地図に渡さず、閉じたあとに処理する
        .onChange(of: showSettings || showWatchDashboard) { _, blocked in
            NewMemoRequest.containerBlocked = blocked
            if !blocked && NewMemoRequest.isPending {
                NotificationCenter.default.post(name: .startNewGeoMemo, object: nil)
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
        // プロフィールを設定した直後に、既に取り込んだ依頼へ名前を書き込む（claim）。
        .onChange(of: profiles.count) { _, _ in
            Task { await syncSharedMemos() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didAcceptSharedMemo)) { _ in
            processPendingShares()
            Task {
                await syncSharedMemos()
                await resolveArrivals()
            }
        }
        // 表示されたとき: 表示前に受諾した共有（共有リンクからの初回起動など）を処理し、一度同期する。
        // scenePhase の変化を待たない（初回起動では .active への変化が起きないことがある）。
        .task {
            // 既読の記録の初期化は、最初の同期より前に行う（この版で初めて取り込む依頼を「新着」にするため）
            ReceivedRequestSeenStore.shared.seedIfNeeded(
                existing: allSharedMemos.filter { !$0.isMyRequest }.map(\.ckRecordName))
            processPendingShares()
            #if DEBUG
            // 受け取り画面の見た目確認用（DemoDataSeeder の受け取った依頼を受け取り画面で出す）
            if geomemoApp.isUITesting && CommandLine.arguments.contains("-demoArrival") {
                try? await Task.sleep(for: .seconds(1))
                arrival = .arrival(recordName: "demo-1")
            }
            #endif
            await syncSharedMemos()
            await resolveArrivals()
        }
    }

    /// 設定・見守り・リストを開いている間は渡さない（閉じてから出す）。
    private var arrivalBinding: Binding<ArrivalPresentation?> {
        Binding(
            get: { (showSettings || showWatchDashboard || (showList && !isSideBySide)) ? nil : arrival },
            set: { arrival = $0 }
        )
    }

    /// 保留キューにある受諾済みの共有をフレンド登録する。
    private func processPendingShares() {
        for info in PendingShareQueue.shared.drain() {
            // 断った依頼をもう一度受諾したときは、断った記録を消す（そうしないと取り込まれない）
            DeclinedRequestStore.shared.removeForReaccept(
                rootRecordName: info.rootRecordName, ownerRecordID: info.ownerRecordID)
            registerFriendIfNeeded(info: info)
            awaitingArrivals.append(info)
        }
    }

    // MARK: - 受諾 → 受け取り画面

    /// 受諾した共有に対応する依頼を探し、受け取り画面などを出す。取り込みに時間がかかるときは、
    /// 2 秒後・5 秒後に同期をやり直す（計 3 回）。それでも見つからなければトーストで知らせ、
    /// 後で取り込まれたらバッジの「新着」で気づける。
    private func resolveArrivals() async {
        guard !awaitingArrivals.isEmpty, !isResolvingArrival else { return }
        isResolvingArrival = true
        defer { isResolvingArrival = false }
        let delays: [Duration] = [.zero, .seconds(2), .seconds(5)]
        for (index, delay) in delays.enumerated() {
            if index > 0 {
                try? await Task.sleep(for: delay)
                await syncSharedMemos()
            }
            guard !awaitingArrivals.isEmpty else { return }
            let received = allSharedMemos.filter { !$0.isMyRequest }.map(\.summary)
            let keys = awaitingArrivals.map(\.key)
            if let result = ArrivalResolver.resolve(
                accepted: keys, received: received, newlyInserted: newlyInserted,
                skippedCancelled: skippedCancelled, freshCancelled: freshCancelled
            ) {
                // 見つかった鍵だけを外す。見つからなかったものは次の試行に回す
                let resolved = ArrivalResolver.resolvedKeys(
                    accepted: keys, received: received, newlyInserted: newlyInserted,
                    skippedCancelled: skippedCancelled, freshCancelled: freshCancelled)
                awaitingArrivals.removeAll { info in resolved.contains(info.key) }
                // 出すものが決まった依頼は「新しく取り込んだ」の記録から外す（次の受諾と取り違えない）
                switch result {
                case .arrival(let name), .existing(let name): newlyInserted.remove(name)
                case .list(let names): names.forEach { newlyInserted.remove($0) }
                case .cancelledBeforeOpen: break
                }
                switch result {
                case .cancelledBeforeOpen:
                    announce(String(localized: "The person who sent this request canceled it."))
                default:
                    arrival = result
                }
                if awaitingArrivals.isEmpty { return }
            }
        }
        awaitingArrivals.removeAll()
        announce(String(localized: "Request received. Find it under “Requests” at the top of the map."))
    }

    /// トーストを出し、VoiceOver にも読み上げさせる。
    private func announce(_ message: String) {
        ToastCenter.shared.show(.info(message, duration: 4))
        AccessibilityNotification.Announcement(message).post()
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
    @State private var needsResync = false

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

    /// 同期中に要求が来たら捨てずに覚えておき、終わったあとにもう一度だけ実行する
    /// （受諾の直後は、先に走っていた同期が受諾前のデータを取り終えていることがあるため）。
    private func syncSharedMemos() async {
        guard !isSyncing else {
            needsResync = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsResync = false
            await syncSharedMemosOnce()
        } while needsResync
    }

    private func syncSharedMemosOnce() async {
        // プロフィール（表示名）が無くても取り込む。受信者としての名前の書き込みだけ、プロフィールがあるときに行う
        let me = profiles.first
        var importedCount = 0
        var newlyCancelled: [SharedMemo] = []
        // 断った依頼の「共有から抜ける」が失敗していたら、ここで抜け直す
        await retryDeclinedLeaves()
        let declined = DeclinedRequestStore.shared
        do {
            let received = try await CKShareService.shared.fetchReceivedSharedMemos()
            var didChange = false
            for data in received {
                let recordName = data.ckRecordID.recordName
                // 断った依頼は取り込まず、監視もしない（抜けるのに失敗していても復活させない）
                if declined.contains(recordName) { continue }
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
                    let wasActive = existing.isActive
                    if existing.apply(data) {
                        didChange = true
                        if wasActive && data.status == .cancelled && !existing.isMyRequest { newlyCancelled.append(existing) }
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
                    // まだ取り込んでいない依頼が既に取り消されていれば取り込まない（受諾した人には文で知らせる）
                    if skippedCancelled[recordName] == nil {
                        skippedCancelled[recordName] = zoneOwner
                        if !awaitingArrivals.isEmpty { freshCancelled.insert(recordName) }
                    }
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
                    importedCount += 1
                    newlyInserted.insert(recordName)
                    if let claimingMe {
                        claimRecipient(data.ckRecordID, me: claimingMe)
                    }
                    if data.status == .active {
                        LocationManager.shared.startMonitoring(region: shared.monitoringRegion)
                    }
                }
            }
            if didChange { try? modelContext.save() }
            // 今ある依頼に無い既読の記録は捨てる
            ReceivedRequestSeenStore.shared.prune(
                keeping: Set(allSharedMemos.filter { !$0.isMyRequest }.map(\.ckRecordName)).union(newlyInserted))
            for cancelled in newlyCancelled {
                let name = cancelled.requesterName.trimmingCharacters(in: .whitespacesAndNewlines)
                announce(name.isEmpty
                         ? String(localized: "The person who sent this request canceled it.")
                         : String(format: String(localized: "%@ canceled the request"), name))
            }
            if importedCount > 0 && awaitingArrivals.isEmpty && !isResolvingArrival {
                // 旧版で受諾済みだった依頼が、この版で初めてまとめて取り込まれることがある
                ToastCenter.shared.show(.info(String(localized: "Received requests added: \(importedCount)")))
            }
        } catch {
            // ネットワーク不可は通常運用の一部なので、UI を遮るのは "今ユーザー操作で
            // 取得を期待していたとき" だけにする。ここはバックグラウンド同期なので silent。
        }
    }

    /// 断った依頼で、共有から抜けるのに失敗したものを抜け直す。成功（すでに無い場合を含む）したら記録を消す。
    private func retryDeclinedLeaves() async {
        let store = DeclinedRequestStore.shared
        for (recordName, zoneOwner) in store.entries {
            let zoneID = CKRecordZone.ID(zoneName: CKShareService.sharingZoneName, ownerName: zoneOwner)
            do {
                try await CKShareService.shared.leaveReceivedShare(
                    recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
                store.remove(recordName)
            } catch {
                // すでに共有が無い（取り消された・抜け済み）なら、記録は要らない。それ以外は次の同期で再試行する
                if ShareAcceptFailure.classify(error: error) == .goneOrCancelled { store.remove(recordName) }
            }
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
    let recordName = shared.ckRecordName
    // 抜けるのに失敗しても次の同期で依頼が復活しないよう、断った記録を先に残す（抜けられたら消す）
    DeclinedRequestStore.shared.add(recordName: recordName, zoneOwner: shared.zoneOwnerName)
    LocationManager.shared.stopMonitoring(memoID: shared.geofenceIdentifier)
    SharedMemoNoteStore.setNote("", for: shared.ckRecordName)
    context.delete(shared)
    try? context.save()
    Task {
        do {
            try await CKShareService.shared.leaveReceivedShare(recordID: recordID)
            DeclinedRequestStore.shared.remove(recordName)
        } catch {
            if ShareAcceptFailure.classify(error: error) == .goneOrCancelled {
                DeclinedRequestStore.shared.remove(recordName)
                return
            }
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

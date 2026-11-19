import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import CloudKit
// Phosphor icons loaded from local Assets.xcassets

// Brand colors and Color(hex:) are defined in Theme.swift

// MARK: - Heading Cone Shape

private struct HeadingCone: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // 先端（下）= ドット位置、広がりは上（進行方向）
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        // 上辺を弧にして扇形らしく
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.25)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Map Item (single pin or cluster)
private enum MapItem: Identifiable {
    case single(GeoMemo)
    case cluster(id: String, coordinate: CLLocationCoordinate2D, memos: [GeoMemo])

    var id: String {
        switch self {
        case .single(let memo):
            return memo.id.uuidString
        case .cluster(let id, _, _):
            return id
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .single(let memo):
            return memo.coordinate
        case .cluster(_, let coordinate, _):
            return coordinate
        }
    }
}

// MARK: - Active Sheet
private enum ActiveSheet: Identifiable {
    case memoEditor(coordinate: CLLocationCoordinate2D)
    case clusterList([GeoMemo])

    var id: String {
        switch self {
        case .memoEditor:
            return "editor"
        case .clusterList(let memos):
            return "cluster-\(memos.map(\.id.uuidString).joined())"
        }
    }
}

// MARK: - Clustering Function
private func clusterMemos(_ memos: [GeoMemo], in region: MKCoordinateRegion) -> [MapItem] {
    let cellWidth = region.span.longitudeDelta / 8.0
    let cellHeight = region.span.latitudeDelta / 8.0

    guard cellWidth > 0, cellHeight > 0 else {
        return memos.map { .single($0) }
    }

    var grid: [String: [GeoMemo]] = [:]
    for memo in memos {
        let col = Int(floor(memo.longitude / cellWidth))
        let row = Int(floor(memo.latitude / cellHeight))
        let key = "\(col),\(row)"
        grid[key, default: []].append(memo)
    }

    return grid.map { key, cellMemos in
        if cellMemos.count == 1 {
            return .single(cellMemos[0])
        } else {
            let count = Double(cellMemos.count)
            let avgLat = cellMemos.reduce(0.0) { $0 + $1.latitude } / count
            let avgLon = cellMemos.reduce(0.0) { $0 + $1.longitude } / count
            // グリッドキーをそのまま ID に流用 → sorted().joined() 不要で O(1)
            return .cluster(
                id: "cluster-\(key)",
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                memos: cellMemos
            )
        }
    }
}

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
        guard !info.ownerRecordID.isEmpty else { return }
        let targetID = info.ownerRecordID
        let predicate = #Predicate<FriendConnection> { $0.friendRecordID == targetID }
        var descriptor = FetchDescriptor<FriendConnection>(predicate: predicate)
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor), !existing.isEmpty { return }

        let friend = FriendConnection(
            friendRecordID:    info.ownerRecordID,
            friendDisplayName: info.ownerName.isEmpty ? String(localized: "フレンド") : info.ownerName,
            status:            .accepted,
            inviteCode:        ""  // CKShare ベースでは不要
        )
        modelContext.insert(friend)
        try? modelContext.save()
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

// MARK: - Custom Navigation Bar
struct CustomNavigationBar: View {
    let memoCount: Int
    @Binding var showSettings: Bool
    @Binding var isSearching: Bool
    @Binding var showWatchDashboard: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Logo Icon
            Image("ph-map-trifold-fill")
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundColor(Brand.blue)
            
            // Logo Text
            Text(verbatim: "GEOMEMO")
                .font(.title2.weight(.heavy))
                .foregroundColor(Brand.primaryText)
                // 狭い幅（折りたたみ端末のカバー画面・大きな文字サイズ）でロゴが
                // 「GEOMEM / O」と折り返さないよう 1 行に固定して縮小で収める
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer()
            
            // Memo Count Badge (only show if count > 0)
            if memoCount > 0 {
                Text(String(format: "%02d", memoCount))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Brand.primaryText)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: memoCount)
                    .frame(width: 40, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Brand.border, lineWidth: 1.5)
                    )
                    .accessibilityLabel("\(memoCount) memos")
            }
            
            // Watch Dashboard Button
            Button(action: { showWatchDashboard = true }) {
                Image(systemName: "eye")
                    .font(.body.weight(.medium))
                    .foregroundColor(Brand.primaryText)
                    .frame(width: 32, height: 32)
            }

            // Search Button
            Button(action: { withAnimation(.easeInOut(duration: 0.25)) { isSearching.toggle() } }) {
                Image("ph-magnifying-glass-bold")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundColor(Brand.primaryText)
                    .frame(width: 32, height: 32)
            }
            
            // Settings Button
            Button(action: { showSettings = true }) {
                Image("ph-gear-six-bold")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundColor(Brand.primaryText)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Brand.background)
        .overlay(
            Rectangle()
                .fill(Brand.border)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Single Pin View
private struct SinglePinView: View {
    var color: Color = Brand.blue
    var isRoute: Bool = false

    var body: some View {
        if isRoute {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: 14, height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Brand.background, lineWidth: 2)
                    )
                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Brand.background)
            }
        } else {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(Brand.background, lineWidth: 2)
                )
        }
    }
}

// MARK: - Cluster Pin View
private struct ClusterPinView: View {
    let count: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(Brand.blue)
                .frame(width: 32, height: 32)
            Text("\(count)")
                .font(.footnote.weight(.bold))
                .foregroundColor(.white)
        }
        .overlay(
            Circle()
                .stroke(Brand.background, lineWidth: 2)
                .frame(width: 32, height: 32)
        )
    }
}

// MARK: - Callout View
private struct CalloutView: View {
    let memo: GeoMemo
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(memo.displayTitle)
                        .font(.subheadline.weight(memo.isUntitled ? .regular : .bold))
                        .foregroundColor(memo.isUntitled ? Brand.tertiaryText : Brand.primaryText)
                        .italic(memo.isUntitled)
                        .lineLimit(1)
                    Text(memo.locationName.isEmpty ? String(localized: "Unknown Location") : memo.locationName)
                        .font(.caption)
                        .foregroundColor(Brand.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image("ph-caret-right-bold")
                    .resizable()
                    .frame(width: 12, height: 12)
                    .foregroundColor(Brand.blue)
            }
            .padding(12)
            .frame(width: 220)
            .background(Brand.surface)
            .cornerRadius(8)
            .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Map Snapshot View
private struct MapSnapshotView: View {
    let coordinate: CLLocationCoordinate2D
    let colorIndex: Int
    @State private var snapshot: UIImage?

    var body: some View {
        Group {
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Brand.primaryText.opacity(0.05))
                    .overlay(ProgressView().tint(Brand.primaryText.opacity(0.3)))
            }
        }
        .task {
            guard snapshot == nil else { return }
            snapshot = await MapSnapshotCache.shared.snapshot(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                colorIndex: colorIndex,
                mapStyleRaw: 0
            )
        }
    }
}

// MARK: - Cluster List Sheet
private struct ClusterListSheet: View {
    let memos: [GeoMemo]
    let onSelectMemo: (GeoMemo) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Handle
            RoundedRectangle(cornerRadius: 2)
                .fill(Brand.separator)
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Header
            HStack {
                Text("\(memos.count) memos")
                    .font(.body.weight(.bold))
                    .foregroundColor(Brand.primaryText)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            // Memo list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(memos) { memo in
                        Button {
                            onSelectMemo(memo)
                        } label: {
                            HStack(spacing: 12) {
                                MapSnapshotView(coordinate: memo.coordinate, colorIndex: memo.colorIndex)
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(memo.displayTitle)
                                        .font(.subheadline.weight(memo.isUntitled ? .regular : .semibold))
                                        .foregroundColor(memo.isUntitled ? Brand.tertiaryText : Brand.primaryText)
                                        .italic(memo.isUntitled)
                                        .lineLimit(1)
                                    Text(memo.locationName.isEmpty ? "Unknown Location" : memo.locationName)
                                        .font(.caption)
                                        .foregroundColor(Brand.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image("ph-caret-right-bold")
                                    .resizable()
                                    .frame(width: 12, height: 12)
                                    .foregroundColor(Brand.secondaryText)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .padding(.leading, 80)
                    }
                }
            }
        }
        .background(Brand.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

// MARK: - Search Completer Helper
@Observable
class SearchCompleterHelper: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    func search(_ query: String) {
        guard !query.isEmpty else {
            results = []
            return
        }
        completer.queryFragment = query
    }

    func clear() {
        results = []
        completer.queryFragment = ""
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            self.results = completer.results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}

// MARK: - Map Tab View
struct MapTabView: View {
    let memos: [GeoMemo]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("mapStyle") private var mapStyleRaw: String = GeoMapStyle.mono.rawValue

    @ObservedObject private var locationManager = LocationManager.shared
    @Binding var isSearching: Bool
    @Binding var deepLinkMemoID: UUID?
    @Binding var showList: Bool

    private var currentMapStyle: GeoMapStyle {
        GeoMapStyle(rawValue: mapStyleRaw) ?? .mono
    }

    private func streetLevelRegion(_ coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)
    }
    
    @State private var shouldJumpToLocation = false
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671),
                           latitudinalMeters: 5000, longitudinalMeters: 5000)
    )
    @State private var newMemoCoordinate: CLLocationCoordinate2D?
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var mapItems: [MapItem] = []
    @State private var showPaywall = false
    @ObservedObject private var store = StoreKitManager.shared
    @State private var clusterTask: Task<Void, Never>?
    @State private var calloutMemo: GeoMemo?
    @State private var activeSheet: ActiveSheet?
    /// 地図上でタップした受信依頼。
    @State private var mapSelectedReceived: SharedMemo?
    @Query(sort: \SharedMemo.createdAt, order: .reverse) private var mapSharedMemos: [SharedMemo]
    private var receivedPins: [SharedMemo] {
        mapSharedMemos.filter { !$0.isMyRequest && ($0.status == .active || $0.status == .fired) }
    }
    @State private var activeDetailMemo: GeoMemo?
    @State private var pendingDetailMemo: GeoMemo?
    /// 遅延して `activeDetailMemo` をセットする Task。新しい遅延が始まる前に cancel する。
    @State private var deferredDetailTask: Task<Void, Never>?
    
    @State private var searchText = ""
    @State private var memoResults: [GeoMemo] = []
    @State private var searchCompleter = SearchCompleterHelper()
    @State private var searchDebounceTask: Task<Void, Never>?
    
    var body: some View {
        ZStack(alignment: .top) {
            mapView
            locationButton
            addMemoButton
            
            if isSearching {
                searchOverlay
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isSearching)
        .sheet(item: $mapSelectedReceived) { shared in
            ReceivedSharedMemoDetailView(shared: shared) {
                deleteReceivedSharedMemo(shared, in: modelContext)
            }
        }
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { sheet in
            sheetContent(for: sheet)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .fullScreenCover(item: $activeDetailMemo, onDismiss: handleSheetDismiss) { memo in
            NavigationStack {
                MemoDetailView(memo: memo)
            }
        }
        .onAppear {
            locationManager.refreshLocation()
            locationManager.startHeading()
            if let userLocation = locationManager.location?.coordinate {
                cameraPosition = .region(streetLevelRegion(userLocation))
            }
            reRegisterAllGeofences()
            // Pass-through 通知の対象を LocationManager に同期（接近時 Dynamic Island 表示）。
            // フォアグラウンド中のみ動作（バックグラウンド対応は別途審査が必要）。
            locationManager.updatePassMemos(memos)

            // Start Live Activity for Dynamic Island
            LiveActivityManager.shared.startMonitoring(count: memos.count)
        }
        .onDisappear {
            locationManager.stopHeading()
        }
        .onChange(of: locationManager.location) { oldValue, newValue in
            guard let userLocation = newValue?.coordinate else { return }
            if oldValue == nil {
                cameraPosition = .region(streetLevelRegion(userLocation))
            } else if shouldJumpToLocation {
                shouldJumpToLocation = false
                withAnimation { cameraPosition = .region(streetLevelRegion(userLocation)) }
            }
        }
        .onChange(of: memos.count) { _, _ in
            scheduleCluster()
            // メモ追加/削除で pass-through 監視対象も更新する。
            locationManager.updatePassMemos(memos)
        }
        .onChange(of: deepLinkMemoID) { _, newID in
            guard let id = newID else { return }
            deepLinkMemoID = nil
            if let memo = memos.first(where: { $0.id == id }) {
                calloutMemo = memo
                withAnimation {
                    cameraPosition = .region(
                        MKCoordinateRegion(
                            center: memo.coordinate,
                            latitudinalMeters: 500,
                            longitudinalMeters: 500
                        )
                    )
                }
                deferredDetailTask?.cancel()
                deferredDetailTask = Task {
                    try? await Task.sleep(for: .seconds(0.5))
                    guard !Task.isCancelled else { return }
                    activeDetailMemo = memo
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.didEnterGeoMemoRegion)) { notification in
            if let id = notification.object as? String,
               let memo = memos.first(where: { $0.id.uuidString == id }) {
                guard memo.notifyOnEntry && !memo.isDone else { return }
                guard locationManager.shouldNotify(for: memo) else { return }
                Task {
                    if let dwell = memo.dwellMinutes {
                        await NotificationManager.shared.scheduleDwellNotification(
                            title: memo.title,
                            body: memo.note,
                            memoID: id,
                            dwellMinutes: dwell
                        )
                    } else {
                        await NotificationManager.shared.scheduleImmediateNotification(
                            title: memo.title,
                            body: memo.note,
                            memoID: id
                        )
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didExitGeoMemoRegion)) { notification in
            if let id = notification.object as? String,
               let memo = memos.first(where: { $0.id.uuidString == id }) {
                // キャンセル：滞在タイマー通知（退場前に発火していなければ取り消す）
                NotificationManager.shared.cancelDwellNotification(memoID: id)

                guard memo.notifyOnExit && !memo.isDone else { return }
                guard locationManager.shouldNotify(for: memo) else { return }
                Task {
                    await NotificationManager.shared.scheduleExitNotification(
                        title: memo.title,
                        body: memo.note,
                        memoID: id,
                        delayMinutes: memo.exitDelayMinutes
                    )
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .geoMemoMarkDone)) { notification in
            if let id = notification.object as? String,
               let memo = memos.first(where: { $0.id.uuidString == id }) {
                memo.isDone = true
                HapticManager.notification(.success)
                if memo.isRouteTrigger {
                    locationManager.stopMonitoringRoute(memoID: id)
                } else {
                    locationManager.stopMonitoring(memoID: id)
                }
            }
        }
    }
    
    // MARK: - Map View
    private var mapView: some View {
        MapReader { proxy in
            Map(position: $cameraPosition, interactionModes: .all) {
                UserAnnotation {
                    ZStack {
                        // TimelineView で描画レート（60/120fps）に同期し、
                        // EMA の滑らかな値をフレームごとに読み取って補間効果を得る
                        TimelineView(.animation) { _ in
                            if locationManager.smoothedHeadingDegrees >= 0 {
                                HeadingCone()
                                    .fill(
                                        LinearGradient(
                                            colors: [Brand.blue.opacity(0.5), Brand.blue.opacity(0.0)],
                                            startPoint: UnitPoint(x: 0.5, y: 0.5),
                                            endPoint: .top
                                        )
                                    )
                                    .frame(width: 36, height: 56)
                                    .padding(.bottom, 56)
                                    .rotationEffect(.degrees(locationManager.smoothedHeadingDegrees))
                            }
                        }
                        Circle()
                            .stroke(Brand.blue.opacity(0.5), lineWidth: 2.5)
                            .frame(width: 36, height: 36)
                        Image("ph-person-simple-bold")
                            .resizable()
                            .frame(width: 22, height: 22)
                            .foregroundColor(Brand.blue)
                            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                    }
                }
                
                // 受信した依頼 (他の人から届いた場所メモ): 範囲の円 + ピン
                ForEach(receivedPins) { shared in
                    MapCircle(center: shared.memoCoordinate, radius: shared.memoRadius)
                        .foregroundStyle(Brand.blue.opacity(0.12))
                        .stroke(Brand.blue.opacity(0.6), lineWidth: 1.5)
                }
                ForEach(receivedPins) { shared in
                    Annotation("", coordinate: shared.memoCoordinate) {
                        ZStack {
                            Circle()
                                .fill(Brand.blue)
                                .frame(width: 30, height: 30)
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .onTapGesture { mapSelectedReceived = shared }
                        .accessibilityLabel(String(localized: "受信した依頼: ") + shared.memoTitle)
                        .accessibilityAddTraits(.isButton)
                    }
                }

                ForEach(mapItems) { item in
                    switch item {
                    case .single(let memo):
                        Annotation("", coordinate: memo.coordinate) {
                            SinglePinView(
                                color: memo.isDone
                                    ? Brand.primaryText.opacity(0.3)
                                    : (MemoColor(rawValue: memo.colorIndex)?.color ?? Brand.blue),
                                isRoute: memo.isRouteTrigger && !memo.isDone
                            )
                            .onTapGesture {
                                calloutMemo = memo
                            }
                        }
                    case .cluster(_, let coordinate, let clusterMemos):
                        Annotation("", coordinate: coordinate) {
                            ClusterPinView(count: clusterMemos.count)
                                .onTapGesture {
                                    calloutMemo = nil
                                    activeSheet = .clusterList(clusterMemos)
                                }
                        }
                    }
                }

                if let calloutMemo {
                    Annotation("", coordinate: calloutMemo.coordinate, anchor: .bottom) {
                        CalloutView(memo: calloutMemo) {
                            let memo = calloutMemo
                            self.calloutMemo = nil
                            activeDetailMemo = memo
                        }
                        .offset(y: -8)
                    }
                }
            }
            .mapStyle({
                switch currentMapStyle {
                case .satellite: return .imagery
                case .detail:    return .standard(elevation: .flat, emphasis: .automatic, pointsOfInterest: .all, showsTraffic: false)
                case .transit:   return .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .including([.publicTransport]), showsTraffic: false)
                default:         return .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false)
                }
            }())
            .grayscale(currentMapStyle == .mono && colorScheme != .dark ? 1.0 : 0)
            .id(mapStyleRaw)
            .mapControlVisibility(.hidden)
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
                scheduleCluster()
            }
            .onTapGesture { screenCoordinate in
                if calloutMemo != nil {
                    calloutMemo = nil
                    return
                }
                if let coordinate = proxy.convert(screenCoordinate, from: .local) {
                    newMemoCoordinate = coordinate
                }
            }
        }
    }
    
    
    // MARK: - Location Button
    private var locationButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    // 現在地へ移動するボタン
                    Button(action: {
                        HapticManager.impact(.light)
                        // 最新位置を取得してからカメラを動かす
                        shouldJumpToLocation = true
                        locationManager.refreshLocation()
                    }) {
                        Image("ph-navigation-arrow-fill")
                            .resizable()
                            .frame(width: 20, height: 20)
                            .foregroundColor(Brand.blue)
                            .frame(width: 48, height: 48)
                            .background(Brand.background)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Brand.border, lineWidth: 1))
                    }

                    // リスト画面へ遷移するボタン
                    Button(action: {
                        HapticManager.impact(.light)
                        // compact ではリストがこのボタンを覆うので常に「開く」。
                        // regular（2 ペイン）ではリストペインの開閉トグルとして働く。
                        withAnimation(.easeInOut(duration: 0.3)) { showList.toggle() }
                    }) {
                        Image("ph-list-bullets")
                            .resizable()
                            .frame(width: 22, height: 22)
                            .foregroundColor(Brand.primaryText)
                            .frame(width: 48, height: 48)
                            .background(Brand.background)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Brand.border, lineWidth: 1))
                    }
                    .accessibilityIdentifier("listViewButton")
                }
                .padding(.trailing, 16)
                // ADD MEMO ボタン (高さ ~72pt + bottom 16pt) と重ならないように、
                // 下端をその上に十分余裕を持って配置する。
                .padding(.bottom, 112)
            }
        }
    }

    // MARK: - Add Memo Button
    private var addMemoButton: some View {
        VStack {
            Spacer()
            Button(action: {
                HapticManager.impact(.medium)
                // Free プランかつ上限に達している場合はペイウォールを表示
                if !store.isPro && memos.count >= GeoMemoLimits.freeMemoLimit {
                    showPaywall = true
                    return
                }
                let defaultTokyo = CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671)
                let coordinate = newMemoCoordinate
                    ?? locationManager.location?.coordinate
                    ?? visibleRegion?.center
                    ?? defaultTokyo
                newMemoCoordinate = coordinate
                calloutMemo = nil
                activeSheet = .memoEditor(coordinate: coordinate)
            }) {
                HStack(spacing: 8) {
                    Image("ph-plus-bold")
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text("ADD MEMO")
                        .font(.body.weight(.heavy))
                }
                .foregroundColor(Brand.primaryText)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 56)
                .padding(.vertical, 8)
                .background(Brand.background)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Brand.border, lineWidth: 2)
                )
            }
            // containerRelativeFrame はウインドウ幅基準になり、2 ペイン時にマップペインを
            // 押し広げてしまうため、親ペイン幅に追従する余白 + 上限幅で決める
            // （iPhone 402pt 幅で従来の 80% ≒ 322pt と同等）。
            .frame(maxWidth: 480)
            .padding(.horizontal, 40)
            .padding(.bottom, 16)
        }
    }
    
    // MARK: - Sheet Handling
    private func handleSheetDismiss() {
        if let memo = pendingDetailMemo {
            pendingDetailMemo = nil
            deferredDetailTask?.cancel()
            deferredDetailTask = Task {
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled else { return }
                activeDetailMemo = memo
            }
        }
    }
    
    @ViewBuilder
    private func sheetContent(for sheet: ActiveSheet) -> some View {
        switch sheet {
        case .memoEditor(let coordinate):
            MemoEditorView(mode: .create(coordinate: coordinate))
        case .clusterList(let clusterMemos):
            ClusterListSheet(memos: clusterMemos) { selectedMemo in
                pendingDetailMemo = selectedMemo
                activeSheet = nil
            }
        }
    }

    // MARK: - Search Overlay
    private var searchOverlay: some View {
        VStack(spacing: 0) {
            // Search Bar
            HStack(spacing: 8) {
                Image("ph-magnifying-glass")
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundColor(Brand.secondaryText)
                TextField("Search memos & places...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onChange(of: searchText) { _, newValue in
                        searchDebounceTask?.cancel()
                        if newValue.isEmpty {
                            performSearch("")
                        } else {
                            searchDebounceTask = Task {
                                try? await Task.sleep(for: .milliseconds(300))
                                guard !Task.isCancelled else { return }
                                performSearch(newValue)
                            }
                        }
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchCompleter.clear()
                        memoResults = []
                    } label: {
                        Image("ph-x-circle-fill")
                            .resizable()
                            .frame(width: 16, height: 16)
                            .foregroundColor(Brand.secondaryText)
                    }
                }
                Button("Cancel") {
                    HapticManager.selection()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isSearching = false
                        searchText = ""
                        searchCompleter.clear()
                        memoResults = []
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(Brand.blue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Brand.background)

            Rectangle()
                .fill(Brand.border)
                .frame(height: 1)

            // Search Results
            if !searchText.isEmpty {
                SearchResultsView(
                    memoResults: memoResults,
                    placeResults: searchCompleter.results,
                    onMemoSelected: { memo in focusOnMemo(memo) },
                    onPlaceSelected: { completion in focusOnPlace(completion) }
                )
            }
        }
    }
    
    // MARK: - Search Logic
    private func performSearch(_ query: String) {
        guard !query.isEmpty else {
            memoResults = []
            searchCompleter.clear()
            return
        }

        memoResults = memos.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.note.localizedCaseInsensitiveContains(query) ||
            $0.locationName.localizedCaseInsensitiveContains(query)
        }

        searchCompleter.search(query)
    }
    
    // MARK: - Focus Actions
    private func focusOnMemo(_ memo: GeoMemo) {
        withAnimation(.easeInOut(duration: 0.25)) {
            isSearching = false
        }
        searchText = ""
        searchCompleter.clear()
        memoResults = []
        calloutMemo = memo

        withAnimation {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: memo.coordinate,
                    latitudinalMeters: 500,
                    longitudinalMeters: 500
                )
            )
        }
    }
    
    private func focusOnPlace(_ completion: MKLocalSearchCompletion) {
        withAnimation(.easeInOut(duration: 0.25)) {
            isSearching = false
        }
        searchText = ""
        searchCompleter.clear()
        memoResults = []

        // MKLocalSearchCompletion → 座標を取得
        let request = MKLocalSearch.Request(completion: completion)
        Task {
            let search = MKLocalSearch(request: request)
            if let response = try? await search.start(),
               let item = response.mapItems.first {
                await MainActor.run {
                    withAnimation { cameraPosition = .region(streetLevelRegion(item.location.coordinate)) }
                }
            }
        }
    }

    /// クラスター計算をバックグラウンドで実行。前回の計算が残っていればキャンセル
    private func scheduleCluster() {
        guard let region = visibleRegion else { return }
        clusterTask?.cancel()
        clusterTask = Task {
            guard !Task.isCancelled else { return }
            mapItems = clusterMemos(memos, in: region)
        }
    }

    /// Re-register geofences for all memos on app launch
    private func reRegisterAllGeofences() {
        locationManager.stopAllMonitoring()
        var registeredRegionCount = 0
        for memo in memos where !memo.isDone {
            if memo.isRouteTrigger {
                locationManager.startMonitoringRoute(for: memo)
                registeredRegionCount += memo.routeWaypoints.count
            } else {
                let region = CLCircularRegion(
                    center: CLLocationCoordinate2D(latitude: memo.latitude, longitude: memo.longitude),
                    radius: memo.radius,
                    identifier: memo.id.uuidString
                )
                region.notifyOnEntry = memo.notifyOnEntry
                region.notifyOnExit = memo.notifyOnExit
                locationManager.startMonitoring(region: region)
                registeredRegionCount += 1
            }
        }
        if registeredRegionCount > 20 {
            print("⚠️ Geofencing limit warning: \(registeredRegionCount) regions registered (iOS limit is 20)")
        }
    }
}

// MARK: - List Tab View
struct ListTabView: View {
    let memos: [GeoMemo]
    @Environment(\.modelContext) private var modelContext

    @ObservedObject private var locationManager = LocationManager.shared
    @State private var selectedTab: FilterTab = .all
    @Namespace private var tabNamespace
    @Binding var intentShowFavorites: Bool
    @Binding var showList: Bool
    @Binding var showSettings: Bool
    @Query(sort: \SharedMemo.createdAt, order: .reverse) private var allSharedMemos: [SharedMemo]

    /// 空状態の大きな装飾アイコンを Dynamic Type に追従させる。
    @ScaledMetric(relativeTo: .largeTitle) private var emptyTabIconSize: CGFloat = 36

    private var receivedActiveMemos: [SharedMemo] {
        allSharedMemos.filter { !$0.isMyRequest && ($0.status == .active || $0.status == .fired) }
    }

    @State private var showDoneSection: Bool = false
    @State private var selectedReceived: SharedMemo?
    @State private var showColorFilter: Bool = false
    @State private var selectedColorIndex: Int? = nil
    @State private var isListSearching = false
    @State private var listSearchText = ""

    // MARK: - Filter Tab

    enum FilterTab: Hashable {
        case favorites
        case all
        case tag(PresetTag)

        var accessibilityLabel: String {
            switch self {
            case .favorites: return String(localized: "Favorites")
            case .all:        return String(localized: "ALL")
            case .tag(let t): return t.localizedName
            }
        }
    }

    // MARK: - Computed Properties

    private var filterTabs: [FilterTab] {
        var tabs: [FilterTab] = [.favorites, .all]
        let usedIds = Set(memos.flatMap { $0.tags })
        tabs += PresetTag.allCases
            .filter { usedIds.contains($0.rawValue) }
            .map { .tag($0) }
        return tabs
    }

    private func memos(for tab: FilterTab) -> [GeoMemo] {
        var results: [GeoMemo]
        switch tab {
        case .favorites: results = memos.filter { $0.isFavorite && !$0.isDone }
        case .all:        results = memos.filter { !$0.isDone }
        case .tag(let t): results = memos.filter { $0.tags.contains(t.rawValue) && !$0.isDone }
        }
        if let colorIndex = selectedColorIndex {
            results = results.filter { $0.colorIndex == colorIndex }
        }
        if !listSearchText.isEmpty {
            let q = listSearchText.lowercased()
            results = results.filter {
                $0.title.lowercased().contains(q) ||
                $0.note.lowercased().contains(q) ||
                $0.locationName.lowercased().contains(q)
            }
        }
        return results
    }

    private var doneMemos: [GeoMemo] {
        memos.filter { $0.isDone }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // カスタムナビゲーションバー（プロダクト名なし）
                listNavigationBar

                // メモ検索バー
                if isListSearching {
                    HStack(spacing: 8) {
                        Image("ph-magnifying-glass-bold")
                            .resizable()
                            .frame(width: 16, height: 16)
                            .foregroundColor(Brand.tertiaryText)
                        TextField(String(localized: "Search memos..."), text: $listSearchText)
                            .font(.body)
                            .foregroundColor(Brand.primaryText)
                        if !listSearchText.isEmpty {
                            Button(action: { listSearchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(Brand.secondaryText)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Brand.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if memos.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image("ph-map-trifold-thin")
                            .resizable()
                            .frame(width: 48, height: 48)
                            .foregroundColor(Brand.primaryText.opacity(0.45))
                        Text("No memos yet")
                            .font(.body.weight(.medium))
                            .foregroundColor(Brand.primaryText.opacity(0.5))
                        Text("Tap the map to add a memo")
                            .font(.subheadline)
                            .foregroundColor(Brand.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    Spacer()
                } else {
                    tabBar
                    pageContent
                }
            }
            .background(Brand.background)
            .navigationBarHidden(true)
            .sheet(item: $selectedReceived) { shared in
                ReceivedSharedMemoDetailView(shared: shared) {
                    deleteReceivedSharedMemo(shared, in: modelContext)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isListSearching)
        }
        .onChange(of: intentShowFavorites) { _, newValue in
            if newValue {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    selectedTab = .favorites
                }
                intentShowFavorites = false
            }
        }
    }

    // MARK: - List Navigation Bar
    private var listNavigationBar: some View {
        HStack(spacing: 12) {
            // マップへ戻るボタン
            Button(action: {
                HapticManager.impact(.light)
                withAnimation(.easeInOut(duration: 0.3)) { showList = false }
            }) {
                HStack(spacing: 4) {
                    Image("ph-arrow-left-bold")
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text("MAP")
                        .font(.body.weight(.bold))
                }
                .foregroundColor(Brand.primaryText)
            }

            Spacer()

            // メモ検索ボタン
            Button(action: {
                withAnimation(.easeInOut(duration: 0.25)) { isListSearching.toggle() }
                if !isListSearching { listSearchText = "" }
            }) {
                Image("ph-magnifying-glass-bold")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundColor(isListSearching ? Brand.blue : Brand.primaryText)
                    .frame(width: 32, height: 32)
            }

            // 設定ボタン
            Button(action: { showSettings = true }) {
                Image("ph-gear-six-bold")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundColor(Brand.primaryText)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Brand.background)
        .overlay(Rectangle().fill(Brand.border).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Tab Bar

    private var usedColors: [MemoColor] {
        let indices = Set(memos.filter { !$0.isDone }.map { $0.colorIndex })
        return MemoColor.allCases.filter { indices.contains($0.rawValue) }
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    ScrollViewReader { proxy in
                        HStack(spacing: 0) {
                            ForEach(filterTabs, id: \.self) { tab in
                                tabButton(tab)
                            }
                        }
                        .padding(.horizontal, 8)
                        .onChange(of: selectedTab) { _, newTab in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(newTab, anchor: .center)
                            }
                        }
                    }
                }

                // Color Filter Toggle Button
                if usedColors.count > 1 {
                    Button {
                        HapticManager.selection()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showColorFilter.toggle()
                            if !showColorFilter { selectedColorIndex = nil }
                        }
                    } label: {
                        ZStack {
                            if let ci = selectedColorIndex,
                               let color = MemoColor(rawValue: ci)?.color {
                                Circle()
                                    .fill(color)
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "circle.grid.3x3")
                                    .font(.subheadline)
                                    .foregroundColor(showColorFilter ? Brand.blue : Brand.secondaryText)
                            }
                        }
                        .frame(width: 44, height: 44)
                    }
                    .padding(.trailing, 4)
                }
            }

            // Accordion Color Filter
            if showColorFilter && usedColors.count > 1 {
                HStack(spacing: 12) {
                    // "All" (no color filter)
                    Button {
                        HapticManager.selection()
                        selectedColorIndex = nil
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Brand.secondaryBackground)
                                .frame(width: 28, height: 28)
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(selectedColorIndex == nil ? Brand.primaryText : Brand.secondaryText)
                        }
                        .overlay(
                            Circle()
                                .stroke(selectedColorIndex == nil ? Brand.primaryText : Color.clear, lineWidth: 2)
                        )
                    }

                    ForEach(usedColors, id: \.rawValue) { memoColor in
                        Button {
                            HapticManager.selection()
                            if selectedColorIndex == memoColor.rawValue {
                                selectedColorIndex = nil
                            } else {
                                selectedColorIndex = memoColor.rawValue
                            }
                        } label: {
                            Circle()
                                .fill(memoColor.color)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle()
                                        .stroke(Brand.primaryText, lineWidth: selectedColorIndex == memoColor.rawValue ? 2 : 0)
                                )
                                .overlay(
                                    Circle()
                                        .stroke(Brand.background, lineWidth: selectedColorIndex == memoColor.rawValue ? 3 : 0)
                                        .padding(2)
                                )
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Brand.secondaryBackground)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Brand.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Brand.border)
                .frame(height: 1)
        }
        .animation(.easeInOut(duration: 0.2), value: showColorFilter)
    }

    private func tabButton(_ tab: FilterTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            HapticManager.selection()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                prevTab = selectedTab
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 0) {
                tabLabel(tab, isSelected: isSelected)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .animation(.easeInOut(duration: 0.15), value: isSelected)

                // Sliding underline
                ZStack {
                    if isSelected {
                        Rectangle()
                            .fill(tab == .favorites ? Color(hex: "E5484D") : Brand.blue)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "tabLine", in: tabNamespace)
                    } else {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: 2)
                    }
                }
            }
        }
        .id(tab)
        .accessibilityLabel(tab.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func tabLabel(_ tab: FilterTab, isSelected: Bool) -> some View {
        switch tab {
        case .favorites:
            Image(systemName: isSelected ? "heart.fill" : "heart")
                .font(.subheadline)
                .foregroundColor(isSelected ? Color(hex: "E5484D") : Brand.secondaryText)
        case .all:
            Text(String(localized: "ALL"))
                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? Brand.primaryText : Brand.secondaryText)
        case .tag(let tag):
            Text(tag.localizedName)
                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? Brand.primaryText : Brand.secondaryText)
        }
    }

    // MARK: - Page Content

    @State private var prevTab: FilterTab = .all

    private var pageContent: some View {
        let isForward = filterTabs.firstIndex(of: selectedTab).map { new in
            filterTabs.firstIndex(of: prevTab).map { new >= $0 } ?? true
        } ?? true
        return memoList(for: selectedTab)
            .id(selectedTab)
            .transition(.asymmetric(
                insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
                removal:   .move(edge: isForward ? .leading  : .trailing).combined(with: .opacity)
            ))
    }

    @ViewBuilder
    private func memoList(for tab: FilterTab) -> some View {
        let tabMemos = memos(for: tab)
        if tabMemos.isEmpty && doneMemos.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: tab == .favorites ? "heart" : "tray")
                    .font(.system(size: emptyTabIconSize))
                    .foregroundColor(Brand.primaryText.opacity(0.2))
                Text(tab == .favorites
                     ? String(localized: "No favorites yet")
                     : String(localized: "No matching memos"))
                    .font(.body.weight(.medium))
                    .foregroundColor(Brand.primaryText.opacity(0.4))
                Spacer()
            }
        } else {
            List {
                // 受信した依頼セクション（ALL タブのみ）
                if tab == .all && !receivedActiveMemos.isEmpty {
                    Section {
                        ForEach(receivedActiveMemos) { shared in
                            receivedMemoRow(shared)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedReceived = shared }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        HapticManager.notification(.warning)
                                        deleteReceivedSharedMemo(shared, in: modelContext)
                                    } label: {
                                        Label(String(localized: "削除"), systemImage: "trash")
                                    }
                                }
                                .accessibilityAddTraits(.isButton)
                                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                                .listRowSeparator(.visible, edges: .bottom)
                                .listRowSeparatorTint(Brand.primaryText.opacity(0.1))
                                .listRowBackground(Brand.surface.opacity(0.6))
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.2.fill")
                                .font(.caption2.weight(.semibold))
                            Text(String(localized: "受信した依頼") + " (\(receivedActiveMemos.count))")
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                        }
                        .foregroundColor(Brand.blue)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                    }
                }

                // 通常メモ
                ForEach(tabMemos) { memo in
                    NavigationLink(destination: MemoDetailView(memo: memo)) {
                        MemoListRow(memo: memo, userLocation: locationManager.location?.coordinate)
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                    .listRowSeparator(.visible, edges: .bottom)
                    .listRowSeparatorTint(Brand.primaryText.opacity(0.1))
                    .listRowBackground(Brand.background)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))
                    .swipeActions(edge: .leading) {
                        Button {
                            HapticManager.notification(.success)
                            memo.isDone = true
                            if memo.isRouteTrigger {
                                locationManager.stopMonitoringRoute(memoID: memo.id.uuidString)
                            } else {
                                locationManager.stopMonitoring(memoID: memo.id.uuidString)
                            }
                        } label: {
                            Label("Complete", systemImage: "checkmark")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            HapticManager.notification(.warning)
                            delete(memo)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

                // 完了済みセクション
                if !doneMemos.isEmpty {
                    Section {
                        if showDoneSection {
                            ForEach(doneMemos) { memo in
                                NavigationLink(destination: MemoDetailView(memo: memo)) {
                                    MemoListRow(memo: memo, userLocation: locationManager.location?.coordinate)
                                }
                                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                                .listRowSeparator(.visible, edges: .bottom)
                                .listRowSeparatorTint(Brand.primaryText.opacity(0.1))
                                .listRowBackground(Brand.background)
                                .swipeActions(edge: .leading) {
                                    Button {
                                        HapticManager.impact(.light)
                                        memo.isDone = false
                                        if memo.isRouteTrigger {
                                            locationManager.startMonitoringRoute(for: memo)
                                        } else if let region = memo.region {
                                            locationManager.startMonitoring(region: region)
                                        }
                                    } label: {
                                        Label("Restore", systemImage: "arrow.uturn.left")
                                    }
                                    .tint(Brand.blue)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        HapticManager.notification(.warning)
                                        delete(memo)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } header: {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showDoneSection.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showDoneSection ? "chevron.down" : "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                Text("Complete (\(doneMemos.count))")
                                    .font(.caption.weight(.semibold))
                                    .textCase(nil)
                            }
                            .foregroundColor(Brand.secondaryText)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Brand.background)
        }
    }

    // MARK: - Received Shared Memo Row

    @ViewBuilder
    private func receivedMemoRow(_ shared: SharedMemo) -> some View {
        HStack(spacing: 12) {
            // ステータスアイコン
            Group {
                if shared.status == .fired {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "clock")
                        .foregroundStyle(Brand.blue)
                }
            }
            .font(.body)
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(shared.memoTitle.isEmpty ? String(localized: "（タイトルなし）") : shared.memoTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                    .lineLimit(1)
                Text(String(localized: "依頼: ") + shared.requesterName)
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
            }

            Spacer()

            // 手動完了ボタン（発火後のみ表示）
            if shared.status == .fired {
                Button {
                    HapticManager.notification(.success)
                    completeSharedMemo(shared)
                } label: {
                    Text(String(localized: "完了"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Brand.blue)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func completeSharedMemo(_ shared: SharedMemo) {
        let now = Date()
        shared.status      = .completed
        shared.completedAt = now
        LocationManager.shared.stopMonitoring(memoID: shared.geofenceIdentifier)
        try? modelContext.save()
        let recordID = shared.cloudKitRecordID
        let owner = shared.zoneOwnerName
        Task {
            do {
                try await CKShareService.shared.updateStatus(recordID: recordID, status: .completed, date: now)
            } catch {
                PendingEventQueue.shared.enqueue(
                    .completed(ckRecordName: shared.ckRecordName, zoneOwnerName: owner, completedAt: now)
                )
            }
        }
    }

    // MARK: - Actions

    private func delete(_ memo: GeoMemo) {
        locationManager.stopMonitoring(memoID: memo.id.uuidString)
        let removedID = memo.id
        modelContext.delete(memo)
        geomemoApp.handleMemoDeleted(id: removedID)
    }
}

// MARK: - Memo List Row
struct MemoListRow: View {
    let memo: GeoMemo
    let userLocation: CLLocationCoordinate2D?
    
    @State private var mapSnapshot: UIImage?
    
    var body: some View {
        HStack(spacing: 12) {
            // Map Thumbnail
            Group {
                if let snapshot = mapSnapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Brand.primaryText.opacity(0.05))
                        .overlay(
                            ProgressView()
                                .tint(Brand.primaryText.opacity(0.3))
                        )
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                // Title
                HStack(spacing: 6) {
                    if memo.colorIndex != 0 {
                        Circle()
                            .fill(MemoColor(rawValue: memo.colorIndex)?.color ?? Brand.blue)
                            .frame(width: 8, height: 8)
                    }
                    if memo.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundColor(Color(hex: "E5484D"))
                            .accessibilityLabel("Favorite")
                    }
                    Text(memo.displayTitle)
                        .font(.body.weight(memo.isUntitled ? .regular : .bold))
                        .foregroundColor(memo.isUntitled ? Brand.tertiaryText : (memo.isDone ? Brand.primaryText.opacity(0.4) : Brand.primaryText))
                        .italic(memo.isUntitled)
                        .strikethrough(memo.isDone, color: Brand.primaryText.opacity(0.4))
                        .lineLimit(1)
                }
                
                // Note
                if !memo.note.isEmpty {
                    Text(memo.note)
                        .font(.subheadline)
                        .foregroundColor(Brand.primaryText.opacity(0.6))
                        .lineLimit(1)
                }
                
                // Location Info
                HStack(spacing: 4) {
                    Text(locationText)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(Brand.secondaryText)
                        .textCase(.uppercase)
                    
                    if let distanceText {
                        Text("•")
                            .font(.caption2.weight(.medium))
                            .foregroundColor(Brand.secondaryText)
                        
                        Text(distanceText)
                            .font(.caption2.weight(.medium))
                            .foregroundColor(Brand.secondaryText)
                    }
                }
            }
            
            Spacer()
        }
        .contentShape(Rectangle())
        .onAppear {
            generateMapSnapshot()
        }
    }
    
    private var locationText: String {
        if memo.locationName.isEmpty || memo.locationName == "LOCATION" {
            return String(localized: "Not fetched")
        }
        return memo.locationName
    }
    
    private var distanceText: String? {
        guard let userLocation = userLocation else {
            return nil
        }
        
        let userCLLocation = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let memoCLLocation = CLLocation(latitude: memo.latitude, longitude: memo.longitude)
        let meters = userCLLocation.distance(from: memoCLLocation)
        
        if meters < 1000 {
            return "\(Int(meters))m"
        } else {
            return String(format: "%.1fkm", meters / 1000)
        }
    }
    
    private func generateMapSnapshot() {
        Task {
            let image = await MapSnapshotCache.shared.snapshot(
                latitude: memo.latitude,
                longitude: memo.longitude,
                colorIndex: memo.colorIndex,
                mapStyleRaw: 0,
                size: CGSize(width: 120, height: 120)
            )
            await MainActor.run {
                mapSnapshot = image
            }
        }
    }
}

// MARK: - Search Results View
private struct SearchResultsView: View {
    let memoResults: [GeoMemo]
    let placeResults: [MKLocalSearchCompletion]
    let onMemoSelected: (GeoMemo) -> Void
    let onPlaceSelected: (MKLocalSearchCompletion) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !memoResults.isEmpty {
                    SectionHeader(title: String(localized: "SAVED MEMOS"))
                    ForEach(memoResults) { memo in
                        MemoResultRow(memo: memo)
                            .onTapGesture { onMemoSelected(memo) }
                        Divider().padding(.leading, 52)
                    }
                }

                if !placeResults.isEmpty {
                    SectionHeader(title: String(localized: "PLACES"))
                    ForEach(placeResults, id: \.self) { completion in
                        PlaceResultRow(completion: completion)
                            .onTapGesture { onPlaceSelected(completion) }
                        Divider().padding(.leading, 52)
                    }
                }

                if memoResults.isEmpty && placeResults.isEmpty {
                    Text("No results found")
                        .font(.subheadline)
                        .foregroundColor(Brand.secondaryText)
                        .padding(24)
                }
            }
        }
        .background(Brand.background)
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundColor(Brand.secondaryText)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

private struct MemoResultRow: View {
    let memo: GeoMemo
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Brand.blue.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image("ph-map-pin-fill")
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundColor(Brand.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(memo.displayTitle)
                    .font(.subheadline.weight(memo.isUntitled ? .regular : .semibold))
                    .foregroundColor(memo.isUntitled ? Brand.tertiaryText : Brand.primaryText)
                    .italic(memo.isUntitled)
                Text(memo.locationName)
                    .font(.caption)
                    .foregroundColor(Brand.secondaryText)
            }
            Spacer()
            Image("ph-caret-right-bold")
                .resizable()
                .frame(width: 12, height: 12)
                .foregroundColor(Brand.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct PlaceResultRow: View {
    let completion: MKLocalSearchCompletion
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Brand.primaryText.opacity(0.08))
                    .frame(width: 36, height: 36)
                Image("ph-map-trifold-fill")
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundColor(Brand.secondaryText)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(completion.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.primaryText)
                if !completion.subtitle.isEmpty {
                    Text(completion.subtitle)
                        .font(.caption)
                        .foregroundColor(Brand.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image("ph-arrow-up-right-bold")
                .resizable()
                .frame(width: 12, height: 12)
                .foregroundColor(Brand.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
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

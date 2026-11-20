import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import CloudKit

// 地図タブ。ContentView.swift から分離。

// MARK: - Map Tab View
struct MapTabView: View {
    let memos: [GeoMemo]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("mapStyle") private var mapStyleRaw: String = GeoMapStyle.mono.rawValue

    @ObservedObject private var locationManager = LocationManager.shared
    @ObservedObject private var notificationManager = NotificationManager.shared
    @Environment(\.scenePhase) private var scenePhase
    /// 閉じた案内ごとの時刻（JSON の [識別子: 時刻]）。同じ案内は 1 週間出さない。
    @AppStorage("mapGuidanceDismissals") private var guidanceDismissalsJSON = ""
    /// 今出す案内。body のたびには計算せず、材料が変わったとき（recomputeGuidance）だけ更新する。
    @State private var currentGuidance: MapGuidance?
    /// 「常に」のダイアログが出たかを見張る（出なかったときだけ設定アプリを開く）。
    @State private var permissionPerformer = PermissionActionPerformer()
    @Binding var isSearching: Bool
    @Binding var deepLinkMemoID: UUID?
    @Binding var showList: Bool
    /// 受諾した共有に対して出すもの（`ContentView` が決める）。出せるときに出し、出したら nil に戻す。
    @Binding var arrival: ArrivalPresentation?

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
    /// 受け取り画面（受諾した直後）。
    @State private var arrivalMemo: SharedMemo?
    /// 「受信した依頼」の一覧シート。
    @State private var showReceivedList = false
    /// 既読の記録を読み直すための印（詳細・一覧を閉じたときに増やす）。
    @State private var seenTick = 0
    /// 既読の集合・バッジ・下部の表示。body のたびには計算せず、材料が変わったとき（recomputeReceived）だけ更新する。
    @State private var seenNames: Set<String> = []
    @State private var badgeState: ReceivedBadgeState = .hidden
    @State private var homeMode: HomeMode = .standard
    /// 受信した依頼のカードの高さ（右下の丸ボタンの列をその上に置くため）。
    @State private var receivedCardHeight: CGFloat = 0
    @State private var arrivalTask: Task<Void, Never>?
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
            if homeMode == .receiverOnly {
                receivedCardArea
            } else {
                addMemoButton
            }

            // 許可の案内のバナーの下に、受け取った依頼のバッジを縦に並べる（検索中は隠す）
            if !isSearching {
                VStack(alignment: .leading, spacing: 0) {
                    if let guidance = currentGuidance {
                        MapGuidanceBanner(
                            guidance: guidance,
                            onAction: { performGuidanceAction(guidance) },
                            onDismiss: { dismissGuidance(guidance) }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    ReceivedRequestsBadge(state: badgeState) { showReceivedList = true }
                        .padding(.leading, 16)
                        .padding(.top, 8)
                        .transition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isSearching {
                searchOverlay
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isSearching)
        .animation(.easeInOut(duration: 0.25), value: currentGuidance)
        .animation(.easeInOut(duration: 0.25), value: badgeState)
        .onChange(of: arrival) { _, _ in presentArrivalWhenReady() }
        .onChange(of: seenTick) { _, _ in recomputeReceived() }
        .onChange(of: receivedStateKey) { _, _ in recomputeReceived() }
        .onChange(of: isAnotherSheetPresented) { _, presented in
            if !presented { presentArrivalWhenReady() }
        }
        // 設定アプリから戻った直後に、通知の許可状態を読み直す。
        .onChange(of: scenePhase) { _, phase in
            permissionPerformer.scenePhaseChanged(phase)
            if phase == .active {
                notificationManager.checkAuthorizationStatus()
                recomputeReceived() // 完了から 24 時間の判定が時間で変わるため
            }
        }
        // 許可を変えた後（設定アプリから戻った・ダイアログで許可した）に、監視を張り直す。
        // 未許可のうちに登録した領域は効かないため、未許可 → 許可済みになったら登録し直す。
        .onChange(of: locationManager.authorizationStatus) { old, new in
            if !LocationAccess(old).isAuthorized && LocationAccess(new).isAuthorized {
                reRegisterAllGeofences()
                locationManager.updatePassMemos(memos)
            }
            recomputeGuidance()
        }
        .onChange(of: locationManager.isPreciseLocation) { _, _ in recomputeGuidance() }
        .onChange(of: notificationManager.authorizationStatus) { _, _ in recomputeGuidance() }
        .onChange(of: guidanceDismissalsJSON) { _, _ in recomputeGuidance() }
        .onChange(of: mapSharedMemos.count) { _, _ in
            recomputeGuidance()
            recomputeReceived()
        }
        // 受信した依頼が増減したとき・自分のメモが増減したときに、監視を差分で合わせる。
        // 20 件あるときに新しい依頼を取り込んでも、次の起動を待たずに登録される（古いメモが外れる）。
        // 逆に依頼が完了・取り消しになって枠が空けば、外れていた自分のメモが戻る。
        .onChange(of: regionRegistrationKey) { _, _ in
            GeofenceReconciler.reconcile(memos: memos, sharedMemos: mapSharedMemos)
            recomputeGuidance()
        }
        .sheet(item: $mapSelectedReceived, onDismiss: { seenTick += 1 }) { shared in
            ReceivedSharedMemoDetailView(
                shared: shared,
                onDelete: { deleteReceivedSharedMemo(shared, in: modelContext) },
                onComplete: { completeReceivedSharedMemo(shared, in: modelContext) }
            )
        }
        .sheet(item: $arrivalMemo, onDismiss: { seenTick += 1; handleSheetDismiss() }) { shared in
            ReceivedSharedMemoDetailView(
                shared: shared,
                onDelete: { deleteReceivedSharedMemo(shared, in: modelContext) },
                onComplete: { completeReceivedSharedMemo(shared, in: modelContext) },
                isArrival: true
            )
        }
        .sheet(isPresented: $showReceivedList, onDismiss: { seenTick += 1; handleSheetDismiss() }) {
            ReceivedRequestsView()
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
            notificationManager.checkAuthorizationStatus()
            locationManager.refreshLocation()
            locationManager.startHeading()
            if let userLocation = locationManager.location?.coordinate {
                cameraPosition = .region(streetLevelRegion(userLocation))
            }
            recomputeReceived()
            reRegisterAllGeofences()
            // Pass-through 通知の対象を LocationManager に同期（接近時 Dynamic Island 表示）。
            // フォアグラウンド中のみ動作（バックグラウンド対応は別途審査が必要）。
            locationManager.updatePassMemos(memos)
            recomputeGuidance()

            // Start Live Activity for Dynamic Island
            LiveActivityManager.shared.startMonitoring(count: memos.count)
        }
        .onDisappear {
            locationManager.stopHeading()
            permissionPerformer.cancel()
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
            recomputeReceived()
            scheduleCluster()
            // メモ追加/削除で pass-through 監視対象も更新する。
            locationManager.updatePassMemos(memos)
            recomputeGuidance()
        }
        .onChange(of: deepLinkMemoID) { _, newID in
            guard let id = newID else { return }
            deepLinkMemoID = nil
            // 到着の通知をタップしたとき: 受け取った依頼の詳細を開く（自分のメモに無ければ受け取った依頼から探す）
            if memos.first(where: { $0.id == id }) == nil,
               let shared = mapSharedMemos.first(where: { $0.id == id && !$0.isMyRequest }) {
                // ほかのシートが出ていれば、閉じるのを待ってから出す（受諾直後の表示と同じ作法）
                arrival = .existing(recordName: shared.ckRecordName)
            }
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
                recomputeGuidance()
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
                        // 方位の値（EMA で平滑化済み）は更新のたびに再描画される。
                        // TimelineView(.animation) は地図の注釈の中では描画スレッドから呼ばれ、
                        // Swift 6 のメインアクター検査でクラッシュするため使わない。
                        HeadingConeIndicator(degrees: locationManager.smoothedHeadingDegrees)
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
                                .foregroundStyle(Brand.onAccent)
                        }
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
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
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                calloutMemo = memo
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(mapPinAccessibilityLabel(
                                title: memo.displayTitle,
                                locationName: memo.locationName,
                                isDone: memo.isDone))
                            .accessibilityAddTraits(.isButton)
                        }
                    case .cluster(_, let coordinate, let clusterMemos):
                        Annotation("", coordinate: coordinate) {
                            ClusterPinView(count: clusterMemos.count)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    calloutMemo = nil
                                    activeSheet = .clusterList(clusterMemos)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(String(localized: "\(clusterMemos.count) memos"))
                                .accessibilityAddTraits(.isButton)
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
                    .accessibilityLabel(String(localized: "Current location"))

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
                    .accessibilityLabel(String(localized: "List"))

                    // 受け取るだけの人は「ADD MEMO」が無いので、メモの作成は小さい「＋」に残す
                    if homeMode == .receiverOnly {
                        Button(action: startNewMemo) {
                            Image("ph-plus-bold")
                                .resizable()
                                .frame(width: 20, height: 20)
                                .foregroundColor(Brand.primaryText)
                                .frame(width: 48, height: 48)
                                .background(Brand.background)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Brand.border, lineWidth: 1))
                        }
                        .accessibilityLabel(String(localized: "Add Memo"))
                        .accessibilityIdentifier("addMemoPlusButton")
                    }
                }
                .padding(.trailing, 16)
                // ADD MEMO ボタン (高さ ~72pt + bottom 16pt) や受信した依頼のカードと重ならないように、
                // 下端をその上に十分余裕を持って配置する。
                .padding(.bottom, homeMode == .receiverOnly ? max(112, receivedCardHeight + 32) : 112)
            }
        }
    }

    // MARK: - Add Memo Button
    private var addMemoButton: some View {
        VStack {
            Spacer()
            Button(action: startNewMemo) {
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
    
    /// メモの作成を始める（「ADD MEMO」と、受け取るだけの人の「＋」で共通）。
    private func startNewMemo() {
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
    }

    // MARK: - 受け取った依頼（バッジ・カード・受け取り画面）

    private var receivedSharedMemos: [SharedMemo] { mapSharedMemos.filter { !$0.isMyRequest } }

    /// 材料（依頼の増減・状態）が変わったかを見るための印。
    private var receivedStateKey: [String] {
        mapSharedMemos.map { "\($0.ckRecordName):\($0.statusRaw):\($0.isMyRequest)" }
    }

    /// 既読・バッジ・下部の表示を材料が変わったときだけ更新する。
    /// 受信だけの表示にするのは、有効な依頼（到着待ち・到着済み）か、完了から 24 時間以内の依頼が 1 件以上あるとき
    /// （すべて終わったら「ADD MEMO」に戻る）。
    private func recomputeReceived() {
        let items = receivedSharedMemos.map(\.summary)
        seenNames = ReceivedRequestSeenStore.shared.all
        badgeState = ReceivedBadgeState.resolve(items, seen: seenNames)
        homeMode = HomeMode.resolve(
            ownMemoCount: memos.count,
            sentRequestCount: mapSharedMemos.filter(\.isMyRequest).count,
            receivedRequestCount: ReceivedRequestSections.resolve(items, now: Date()).count)
    }

    /// 受け取った依頼を表示している最中か、ほかのシートが出ている間は、受け取り画面を出さずに待つ。
    private var isAnotherSheetPresented: Bool {
        activeSheet != nil || activeDetailMemo != nil || mapSelectedReceived != nil
            || showPaywall || showReceivedList || arrivalMemo != nil
    }

    /// 受諾した共有に対する表示を、ほかのシートが閉じてから出す（閉じるアニメーションと重ならないよう少し待つ）。
    private func presentArrivalWhenReady() {
        guard arrival != nil else { return }
        arrivalTask?.cancel()
        arrivalTask = Task {
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled, let pending = arrival, !isAnotherSheetPresented else { return }
            switch pending {
            case .arrival(let name):
                arrivalMemo = receivedSharedMemos.first { $0.ckRecordName == name }
            case .existing(let name):
                mapSelectedReceived = receivedSharedMemos.first { $0.ckRecordName == name }
            case .list:
                showReceivedList = true
            case .cancelledBeforeOpen:
                break
            }
            arrival = nil
        }
    }

    private var receivedCardArea: some View {
        let items = receivedSharedMemos
        let highlightName = ReceivedHighlight.pick(items.map(\.summary))
        let open = items.filter { $0.isActive }
        return VStack {
            Spacer()
            ReceivedRequestCard(
                highlight: items.first { $0.ckRecordName == highlightName },
                otherCount: max(0, open.count - 1),
                onOpenDetail: { mapSelectedReceived = items.first { $0.ckRecordName == highlightName } },
                onOpenList: { showReceivedList = true },
                onComplete: {
                    if let shared = items.first(where: { $0.ckRecordName == highlightName }) {
                        completeReceivedSharedMemo(shared, in: modelContext)
                    }
                }
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { receivedCardHeight = $0 }
            .frame(maxWidth: 480)
            .padding(.horizontal, 40)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Sheet Handling
    private func handleSheetDismiss() {
        recomputeGuidance() // 詳細画面で完了・削除された分を上限の数え方に反映する
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
    // MARK: - Permission / limit guidance

    /// 監視したいジオフェンスの数（`GeofenceRegistrar` に置いた。「通知のチェック」と共有）。
    private var requiredRegionCount: Int {
        GeofenceRegistrar.requiredRegionCount(memos: memos, sharedMemos: mapSharedMemos)
    }

    /// 監視の登録に影響する材料。変わったときだけ差分で合わせ直す。
    private var regionRegistrationKey: [String] {
        let received = mapSharedMemos.filter { !$0.isMyRequest && $0.status == .active }
            .map(\.geofenceIdentifier).sorted()
        let own = memos.filter { !$0.isDone }.map { "\($0.id.uuidString):\($0.isRouteTrigger ? $0.routeWaypoints.count : 1)" }.sorted()
        return received + own
    }

    /// 案内の材料（メモ・許可状態・閉じた記録）が変わったときだけ呼ぶ。
    private func recomputeGuidance() {
        currentGuidance = MapGuidance.resolve(
            permissions: PermissionSnapshot(
                location: LocationAccess(locationManager.authorizationStatus),
                isPreciseLocation: locationManager.isPreciseLocation,
                notification: NotificationAccess(notificationManager.authorizationStatus)
            ),
            requiredRegions: requiredRegionCount,
            dismissals: MapGuidance.decodeDismissals(guidanceDismissalsJSON)
        )
    }

    /// 許可ダイアログは、バナーのボタンを押したときにだけ出す。動作は `PermissionActionPerformer`。
    private func performGuidanceAction(_ guidance: MapGuidance) {
        guard case .permission(let notice) = guidance, let action = notice.action else { return }
        permissionPerformer.perform(action)
    }

    private func dismissGuidance(_ guidance: MapGuidance) {
        let updated = MapGuidance.recordingDismissal(
            of: guidance, in: MapGuidance.decodeDismissals(guidanceDismissalsJSON))
        guidanceDismissalsJSON = MapGuidance.encodeDismissals(updated)
        recomputeGuidance()
    }

    private func reRegisterAllGeofences() {
        GeofenceRegistrar.reRegisterAll(memos: memos, sharedMemos: mapSharedMemos)
    }
}

import SwiftUI
import SwiftData
import MapKit
import CoreLocation
// Phosphor icons loaded from local Assets.xcassets

// MARK: - Color Extension
private extension Color {
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hexSanitized.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 255, 255, 255)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

// MARK: - Brand Colors
private enum Brand {
    static let white = Color.white
    static let black = Color(hex: "1A1A1A")
    static let blue = Color(hex: "3D3BF3")
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
    case memoDetail(GeoMemo)
    case clusterList([GeoMemo])

    var id: String {
        switch self {
        case .memoEditor:
            return "editor"
        case .memoDetail(let memo):
            return "detail-\(memo.id)"
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

    return grid.values.map { cellMemos in
        if cellMemos.count == 1 {
            return .single(cellMemos[0])
        } else {
            let avgLat = cellMemos.map(\.latitude).reduce(0, +) / Double(cellMemos.count)
            let avgLon = cellMemos.map(\.longitude).reduce(0, +) / Double(cellMemos.count)
            let stableID = "cluster-" + cellMemos.map(\.id.uuidString).sorted().joined(separator: "-")
            return .cluster(
                id: stableID,
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                memos: cellMemos
            )
        }
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @State private var selectedTab: Tab = .map
    @State private var showSettings = false
    @State private var isSearching = false
    
    enum Tab {
        case map
        case list
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // Custom Navigation Bar
                CustomNavigationBar(showSettings: $showSettings, isSearching: $isSearching)
                
                // Content
                Group {
                    switch selectedTab {
                    case .map:
                        MapTabView(isSearching: $isSearching)
                    case .list:
                        ListTabView()
                    }
                }
                
                // Custom Tab Bar
                CustomTabBar(selectedTab: $selectedTab)
            }
        }
        .background(Brand.white)
        .ignoresSafeArea(edges: .bottom)
        .fullScreenCover(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
        }
    }
}

// MARK: - Custom Navigation Bar
struct CustomNavigationBar: View {
    @Query(sort: \GeoMemo.createdAt, order: .reverse) private var memos: [GeoMemo]
    @Binding var showSettings: Bool
    @Binding var isSearching: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // Logo Icon
            Image("ph-map-trifold-fill")
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundColor(Brand.blue)
            
            // Logo Text
            Text("GEOMEMO")
                .font(.system(size: 24, weight: .heavy, design: .default))
                .foregroundColor(Brand.black)
            
            Spacer()
            
            // Memo Count Badge (only show if count > 0)
            if memos.count > 0 {
                Text(String(format: "%02d", memos.count))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Brand.black)
                    .frame(width: 40, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Brand.black, lineWidth: 1.5)
                    )
            }
            
            // Search Button
            Button(action: { withAnimation(.easeInOut(duration: 0.25)) { isSearching.toggle() } }) {
                Image("ph-magnifying-glass-bold")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundColor(Brand.black)
                    .frame(width: 32, height: 32)
            }
            
            // Settings Button
            Button(action: { showSettings = true }) {
                Image("ph-gear-six-bold")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundColor(Brand.black)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Brand.white)
        .overlay(
            Rectangle()
                .fill(Brand.black)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Single Pin View
private struct SinglePinView: View {
    var body: some View {
        Circle()
            .fill(Brand.blue)
            .frame(width: 12, height: 12)
            .overlay(
                Circle()
                    .stroke(Brand.white, lineWidth: 2)
            )
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
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
        }
        .overlay(
            Circle()
                .stroke(Brand.white, lineWidth: 2)
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
                    Text(memo.title.isEmpty ? "（タイトルなし）" : memo.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Brand.black)
                        .lineLimit(1)
                    Text(memo.locationName.isEmpty ? "Unknown Location" : memo.locationName)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "6E6E73"))
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
            .background(Brand.white)
            .cornerRadius(8)
            .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Map Snapshot View
private struct MapSnapshotView: View {
    let coordinate: CLLocationCoordinate2D
    @State private var snapshot: UIImage?

    var body: some View {
        Group {
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Brand.black.opacity(0.05))
                    .overlay(ProgressView().tint(Brand.black.opacity(0.3)))
            }
        }
        .onAppear { generateSnapshot() }
    }

    private func generateSnapshot() {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 500,
            longitudinalMeters: 500
        )
        options.size = CGSize(width: 112, height: 112)
        options.mapType = .mutedStandard

        Task {
            if let result = try? await MKMapSnapshotter(options: options).start() {
                await MainActor.run { snapshot = result.image }
            }
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
                .fill(Color(hex: "E5E5EA"))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Header
            HStack {
                Text("\(memos.count)件のメモ")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Brand.black)
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
                                MapSnapshotView(coordinate: memo.coordinate)
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(memo.title.isEmpty ? "（タイトルなし）" : memo.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(Brand.black)
                                        .lineLimit(1)
                                    Text(memo.locationName.isEmpty ? "Unknown Location" : memo.locationName)
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(hex: "6E6E73"))
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image("ph-caret-right-bold")
                                    .resizable()
                                    .frame(width: 12, height: 12)
                                    .foregroundColor(Color(hex: "6E6E73"))
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
        .background(Brand.white)
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
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GeoMemo.createdAt, order: .reverse) private var memos: [GeoMemo]
    
    @ObservedObject private var locationManager = LocationManager.shared
    @Binding var isSearching: Bool
    
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var newMemoCoordinate: CLLocationCoordinate2D?
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var mapItems: [MapItem] = []
    @State private var calloutMemo: GeoMemo?
    @State private var activeSheet: ActiveSheet?
    @State private var pendingDetailMemo: GeoMemo?
    
    @State private var searchText = ""
    @State private var memoResults: [GeoMemo] = []
    @State private var searchCompleter = SearchCompleterHelper()
    
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
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { sheet in
            sheetContent(for: sheet)
        }
        .onAppear {
            locationManager.refreshLocation()
            if let userLocation = locationManager.location?.coordinate {
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: userLocation,
                        latitudinalMeters: 1000,
                        longitudinalMeters: 1000
                    )
                )
            }
            reRegisterAllGeofences()
        }
        .onChange(of: locationManager.location) { oldValue, newValue in
            if oldValue == nil, let userLocation = newValue?.coordinate {
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: userLocation,
                        latitudinalMeters: 1000,
                        longitudinalMeters: 1000
                    )
                )
            }
        }
        .onChange(of: memos.count) { _, _ in
            if let region = visibleRegion {
                mapItems = clusterMemos(memos, in: region)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.didEnterGeoMemoRegion)) { notification in
            if let id = notification.object as? String,
               let memo = memos.first(where: { $0.id.uuidString == id }) {
                guard locationManager.shouldNotify(for: memo) else { return }
                Task {
                    await NotificationManager.shared.scheduleImmediateNotification(
                        title: memo.title,
                        body: memo.note.isEmpty ? "エリアに入りました" : memo.note
                    )
                }
            }
        }
    }
    
    // MARK: - Map View
    private var mapView: some View {
        MapReader { proxy in
            Map(position: $cameraPosition, interactionModes: .all) {
                UserAnnotation()
                
                ForEach(mapItems) { item in
                    switch item {
                    case .single(let memo):
                        Annotation("", coordinate: memo.coordinate) {
                            SinglePinView()
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
                            activeSheet = .memoDetail(memo)
                        }
                        .offset(y: -8)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .mapControlVisibility(.hidden)
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
                mapItems = clusterMemos(memos, in: context.region)
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
                Button(action: {
                    if let userLocation = locationManager.location?.coordinate {
                        cameraPosition = .region(
                            MKCoordinateRegion(
                                center: userLocation,
                                latitudinalMeters: 1000,
                                longitudinalMeters: 1000
                            )
                        )
                    }
                }) {
                    Image("ph-navigation-arrow-fill")
                        .resizable()
                        .frame(width: 20, height: 20)
                        .foregroundColor(Brand.blue)
                        .frame(width: 48, height: 48)
                        .background(Brand.white)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Brand.black, lineWidth: 1)
                        )
                }
                .padding(.trailing, 16)
                .padding(.bottom, 80)
            }
        }
    }
    
    // MARK: - Add Memo Button
    private var addMemoButton: some View {
        VStack {
            Spacer()
            Button(action: {
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
                        .font(.system(size: 18, weight: .heavy, design: .default))
                }
                .foregroundColor(Brand.black)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Brand.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Brand.black, lineWidth: 2)
                )
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.8)
            .padding(.bottom, 16)
        }
    }
    
    // MARK: - Sheet Handling
    private func handleSheetDismiss() {
        if let memo = pendingDetailMemo {
            pendingDetailMemo = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                activeSheet = .memoDetail(memo)
            }
        }
    }
    
    @ViewBuilder
    private func sheetContent(for sheet: ActiveSheet) -> some View {
        switch sheet {
        case .memoEditor(let coordinate):
            MemoEditorView(mode: .create(coordinate: coordinate))
        case .memoDetail(let memo):
            NavigationStack {
                MemoDetailView(memo: memo)
            }
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
                    .foregroundColor(Brand.black.opacity(0.4))
                TextField("メモ・場所を検索...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .onChange(of: searchText) { _, newValue in
                        performSearch(newValue)
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
                            .foregroundColor(Brand.black.opacity(0.4))
                    }
                }
                Button("キャンセル") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isSearching = false
                        searchText = ""
                        searchCompleter.clear()
                        memoResults = []
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Brand.blue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Brand.white)

            Rectangle()
                .fill(Brand.black)
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
                    withAnimation {
                        cameraPosition = .region(
                            MKCoordinateRegion(
                                center: item.placemark.coordinate,
                                latitudinalMeters: 1000,
                                longitudinalMeters: 1000
                            )
                        )
                    }
                }
            }
        }
    }

    /// Re-register geofences for all memos on app launch
    private func reRegisterAllGeofences() {
        locationManager.stopAllMonitoring()
        for memo in memos {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: memo.latitude, longitude: memo.longitude),
                radius: memo.radius,
                identifier: memo.id.uuidString
            )
            region.notifyOnEntry = memo.notifyOnEntry
            region.notifyOnExit = memo.notifyOnExit
            locationManager.startMonitoring(region: region)
        }
        if memos.count > 20 {
            print("⚠️ Geofencing limit warning: \(memos.count) memos registered (iOS limit is 20)")
        }
    }
}

// MARK: - List Tab View
struct ListTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GeoMemo.createdAt, order: .reverse) private var memos: [GeoMemo]
    
    @ObservedObject private var locationManager = LocationManager.shared
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Memo List
                if memos.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image("ph-map-trifold-thin")
                            .resizable()
                            .frame(width: 48, height: 48)
                            .foregroundColor(Brand.black.opacity(0.3))
                        Text("メモがありません")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(Brand.black.opacity(0.5))
                        Text("MAPタブで地図をタップしてメモを追加してください")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(Brand.black.opacity(0.4))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(memos) { memo in
                            NavigationLink(destination: MemoDetailView(memo: memo)) {
                                MemoListRow(memo: memo, userLocation: locationManager.location?.coordinate)
                            }
                            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                            .listRowSeparator(.visible, edges: .bottom)
                            .listRowSeparatorTint(Brand.black.opacity(0.1))
                            .listRowBackground(Brand.white)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(memo)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Brand.white)
                }
            }
            .background(Brand.white)
            .navigationBarHidden(true)
        }
    }
    
    private func delete(_ memo: GeoMemo) {
        locationManager.stopMonitoring(memoID: memo.id.uuidString)
        modelContext.delete(memo)
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
                        .fill(Brand.black.opacity(0.05))
                        .overlay(
                            ProgressView()
                                .tint(Brand.black.opacity(0.3))
                        )
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                // Title
                Text(memo.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Brand.black)
                    .lineLimit(1)
                
                // Note
                if !memo.note.isEmpty {
                    Text(memo.note)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(Brand.black.opacity(0.6))
                        .lineLimit(1)
                }
                
                // Location Info
                HStack(spacing: 4) {
                    Text(locationText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Brand.black.opacity(0.4))
                        .textCase(.uppercase)
                    
                    if let distanceText {
                        Text("•")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Brand.black.opacity(0.4))
                        
                        Text(distanceText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Brand.black.opacity(0.4))
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
            return "未取得"
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
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: memo.coordinate,
            latitudinalMeters: 500,
            longitudinalMeters: 500
        )
        options.size = CGSize(width: 120, height: 120)
        options.mapType = .standard
        
        let snapshotter = MKMapSnapshotter(options: options)
        
        Task {
            do {
                let snapshot = try await snapshotter.start()
                await MainActor.run {
                    mapSnapshot = snapshot.image
                }
            } catch {
                print("Snapshot error: \(error)")
            }
        }
    }
}

// MARK: - Custom Tab Bar
struct CustomTabBar: View {
    @Binding var selectedTab: ContentView.Tab
    
    var body: some View {
        HStack(spacing: 0) {
            // MAP Tab
            Button(action: { selectedTab = .map }) {
                VStack(spacing: 6) {
                    Image(selectedTab == .map ? "ph-map-trifold-fill" : "ph-map-trifold")
                        .resizable()
                        .frame(width: 24, height: 24)
                    Text("MAP")
                        .font(.system(size: 11, weight: .bold, design: .default))
                }
                .foregroundColor(selectedTab == .map ? Brand.white : Brand.black)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(selectedTab == .map ? Brand.blue : Brand.white)
            }
            
            // LIST Tab
            Button(action: { selectedTab = .list }) {
                VStack(spacing: 6) {
                    Image(selectedTab == .list ? "ph-list-bullets-fill" : "ph-list-bullets")
                        .resizable()
                        .frame(width: 24, height: 24)
                    Text("LIST")
                        .font(.system(size: 11, weight: .bold, design: .default))
                }
                .foregroundColor(selectedTab == .list ? Brand.white : Brand.black)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(selectedTab == .list ? Brand.blue : Brand.white)
            }
        }
        .overlay(
            Rectangle()
                .fill(Brand.black)
                .frame(height: 1),
            alignment: .top
        )
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
                    SectionHeader(title: "登録済みメモ")
                    ForEach(memoResults) { memo in
                        MemoResultRow(memo: memo)
                            .onTapGesture { onMemoSelected(memo) }
                        Divider().padding(.leading, 52)
                    }
                }

                if !placeResults.isEmpty {
                    SectionHeader(title: "場所")
                    ForEach(placeResults, id: \.self) { completion in
                        PlaceResultRow(completion: completion)
                            .onTapGesture { onPlaceSelected(completion) }
                        Divider().padding(.leading, 52)
                    }
                }

                if memoResults.isEmpty && placeResults.isEmpty {
                    Text("結果が見つかりません")
                        .font(.system(size: 14))
                        .foregroundColor(Brand.black.opacity(0.4))
                        .padding(24)
                }
            }
        }
        .background(Brand.white)
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Brand.black.opacity(0.4))
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
                Text(memo.title.isEmpty ? "（タイトルなし）" : memo.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Brand.black)
                Text(memo.locationName)
                    .font(.system(size: 12))
                    .foregroundColor(Brand.black.opacity(0.4))
            }
            Spacer()
            Image("ph-caret-right-bold")
                .resizable()
                .frame(width: 12, height: 12)
                .foregroundColor(Brand.black.opacity(0.4))
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
                    .fill(Brand.black.opacity(0.08))
                    .frame(width: 36, height: 36)
                Image("ph-map-trifold-fill")
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundColor(Brand.black.opacity(0.4))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(completion.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Brand.black)
                if !completion.subtitle.isEmpty {
                    Text(completion.subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(Brand.black.opacity(0.4))
                        .lineLimit(1)
                }
            }
            Spacer()
            Image("ph-arrow-up-right-bold")
                .resizable()
                .frame(width: 12, height: 12)
                .foregroundColor(Brand.black.opacity(0.4))
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

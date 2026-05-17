import SwiftUI
import MapKit
import Combine
import SwiftData
// Phosphor icons loaded from local Assets.xcassets

// Brand colors and Color(hex:) are defined in Theme.swift

// MARK: - Search Completer
private class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var completions: [MKLocalSearchCompletion] = []
    let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    func update(query: String, region: MKCoordinateRegion) {
        completer.region = region
        completer.queryFragment = query
    }

    func clear() {
        completer.queryFragment = ""
        completions = []
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        completions = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        completions = []
    }
}

struct LocationPickerSheetV2: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FavoritePlace.createdAt) private var favoritePlaces: [FavoritePlace]

    let initialCoordinate: CLLocationCoordinate2D
    let radius: Double
    let showFavorites: Bool
    let onLocationSelected: (CLLocationCoordinate2D, String) -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var selectedCoordinate: CLLocationCoordinate2D
    @State private var locationName: String = String(localized: "Loading...")
    @State private var isGeocodingInProgress = false

    // Search
    @State private var searchText: String = ""
    @State private var isSearching = false
    @StateObject private var searchCompleter = SearchCompleter()
    @FocusState private var isSearchFieldFocused: Bool

    // Favorites manager
    @State private var showFavoritesManager = false

    /// Apple Maps 風 bottom sheet の現在の detent。初期は小さい高さで表示して
    /// マップを優先表示し、ユーザーが必要なときだけ引き上げて検索/お気に入りに到達する。
    @State private var sheetDetent: PresentationDetent = .height(160)

    init(initialCoordinate: CLLocationCoordinate2D, radius: Double, showFavorites: Bool = true, onLocationSelected: @escaping (CLLocationCoordinate2D, String) -> Void) {
        self.initialCoordinate = initialCoordinate
        self.radius = radius
        self.showFavorites = showFavorites
        self.onLocationSelected = onLocationSelected
        _selectedCoordinate = State(initialValue: initialCoordinate)
        _cameraPosition = State(initialValue: .camera(
            MapCamera(centerCoordinate: initialCoordinate, distance: 1000)
        ))
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            // 1. 全画面マップ
            mapLayer

            // 2. 上部に「キャンセル」+「選択」のオーバーレイ
            topBar
        }
        .ignoresSafeArea()
        .onAppear {
            reverseGeocode(coordinate: selectedCoordinate)
        }
        // 3. Apple Maps 風 bottom sheet (検索 + お気に入り)
        .sheet(isPresented: .constant(true)) {
            bottomSheet
                .presentationDetents(
                    [.height(160), .medium, .large],
                    selection: $sheetDetent
                )
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showFavoritesManager) {
            FavoritePlacesView()
        }
    }

    // MARK: - Map Layer

    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            Annotation("", coordinate: selectedCoordinate) {
                ZStack {
                    Circle()
                        .fill(Brand.primaryText)
                        .frame(width: 16, height: 16)
                    Circle()
                        .stroke(Brand.background, lineWidth: 3)
                        .frame(width: 16, height: 16)
                }
            }

            // Radius circle
            MapCircle(center: selectedCoordinate, radius: radius)
                .foregroundStyle(Brand.blue.opacity(0.1))
                .stroke(Brand.blue.opacity(0.6), lineWidth: 1.5)
        }
        .mapStyle(.standard(elevation: .realistic))
        .onMapCameraChange { context in
            selectedCoordinate = context.camera.centerCoordinate
        }
        .task(id: "\(selectedCoordinate.latitude),\(selectedCoordinate.longitude)") {
            try? await Task.sleep(for: .milliseconds(300))
            reverseGeocode(coordinate: selectedCoordinate)
        }
    }

    // MARK: - Top Bar (キャンセル + 選択)

    private var topBar: some View {
        HStack(spacing: 12) {
            // キャンセル
            Button(action: { dismiss() }) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundColor(Brand.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
            }

            Spacer(minLength: 0)

            // 現在の選択位置 (中央ピル)
            HStack(spacing: 6) {
                Image("ph-map-pin-fill")
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundColor(Brand.blue)
                Text(locationName)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Brand.primaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .layoutPriority(0)

            Spacer(minLength: 0)

            // 選択
            Button(action: {
                onLocationSelected(selectedCoordinate, locationName)
                dismiss()
            }) {
                Text("SELECT", comment: "location picker confirm")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Brand.blue, in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 56)
    }

    // MARK: - Bottom Sheet (検索 + お気に入り)

    private var bottomSheet: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 検索バー
                HStack(spacing: 8) {
                    Image("ph-magnifying-glass")
                        .resizable()
                        .frame(width: 16, height: 16)
                        .foregroundColor(Brand.primaryText.opacity(0.5))
                        .accessibilityHidden(true)

                    TextField(String(localized: "Search places..."), text: $searchText)
                        .font(.body)
                        .foregroundColor(Brand.primaryText)
                        .focused($isSearchFieldFocused)
                        .submitLabel(.search)
                        .onChange(of: searchText) { _, newValue in
                            if newValue.isEmpty {
                                isSearching = false
                                searchCompleter.clear()
                            } else {
                                isSearching = true
                                sheetDetent = .large  // 検索中はシートを最大化して結果を見せる
                                searchCompleter.update(
                                    query: newValue,
                                    region: MKCoordinateRegion(
                                        center: selectedCoordinate,
                                        span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
                                    )
                                )
                            }
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            isSearching = false
                            searchCompleter.clear()
                            isSearchFieldFocused = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Brand.secondaryText)
                        }
                        .accessibilityLabel(String(localized: "検索をクリア"))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Brand.secondaryBackground, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)

                // お気に入り (検索していないときだけ表示)
                if showFavorites && !isSearching {
                    favoritesSection
                }

                // 検索結果
                if isSearching && !searchCompleter.completions.isEmpty {
                    searchResultsSection
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .presentationBackground(Brand.background)
    }

    // MARK: - Favorites Section

    private var favoritesSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "FAVORITE PLACES"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.secondaryText)
                    .tracking(0.8)
                Spacer()
                Button(String(localized: "Manage")) {
                    showFavoritesManager = true
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Brand.blue)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                if favoritePlaces.isEmpty {
                    Button {
                        showFavoritesManager = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle")
                                .font(.title3)
                                .foregroundStyle(Brand.blue)
                                .frame(minWidth: 24)
                                .accessibilityHidden(true)
                            Text(String(localized: "お気に入りの場所を追加"))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Brand.primaryText)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                } else {
                    ForEach(favoritePlaces) { place in
                        Button {
                            // お気に入りタップで位置選択を確定 → 親シートも閉じる
                            HapticManager.selection()
                            onLocationSelected(place.coordinate, place.name)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: place.iconName)
                                    .font(.body)
                                    .foregroundStyle(Brand.blue)
                                    .frame(width: 24)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Brand.primaryText)
                                    if !place.subtitle.isEmpty {
                                        Text(place.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(Brand.secondaryText)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        if place.id != favoritePlaces.last?.id {
                            Rectangle()
                                .fill(Brand.primaryText.opacity(0.08))
                                .frame(height: 1)
                                .padding(.leading, 52)
                        }
                    }
                }
            }
            .background(Brand.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Search Results Section

    private var searchResultsSection: some View {
        VStack(spacing: 0) {
            ForEach(searchCompleter.completions, id: \.self) { completion in
                Button(action: { selectCompletion(completion) }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(completion.title)
                            .font(.body.weight(.semibold))
                            .foregroundColor(Brand.primaryText)
                        if !completion.subtitle.isEmpty {
                            Text(completion.subtitle)
                                .font(.footnote)
                                .foregroundColor(Brand.primaryText.opacity(0.6))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                if completion != searchCompleter.completions.last {
                    Rectangle()
                        .fill(Brand.primaryText.opacity(0.08))
                        .frame(height: 1)
                        .padding(.leading, 16)
                }
            }
        }
        .background(Brand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }
    
    // MARK: - Reverse Geocoding
    private func reverseGeocode(coordinate: CLLocationCoordinate2D) {
        guard !isGeocodingInProgress else { return }
        isGeocodingInProgress = true

        Task {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard let request = MKReverseGeocodingRequest(location: location) else {
                locationName = String(localized: "Unknown Location")
                isGeocodingInProgress = false
                return
            }
            do {
                let items = try await request.mapItems
                if let item = items.first {
                    let repr = item.addressRepresentations
                    if let city = repr?.cityWithContext, !city.isEmpty {
                        locationName = city
                    } else if let city = repr?.cityName, !city.isEmpty {
                        locationName = city
                    } else if let region = repr?.regionName, !region.isEmpty {
                        locationName = region
                    } else {
                        locationName = item.name ?? String(localized: "Unknown Location")
                    }
                } else {
                    locationName = String(localized: "Unknown Location")
                }
            } catch {
                locationName = String(localized: "Unknown Location")
            }
            isGeocodingInProgress = false
        }
    }
    
    // MARK: - Select Completion
    private func selectCompletion(_ completion: MKLocalSearchCompletion) {
        Task {
            let request = MKLocalSearch.Request(completion: completion)
            let search = MKLocalSearch(request: request)

            do {
                let response = try await search.start()
                if let item = response.mapItems.first {
                    let coordinate = item.location.coordinate
                    cameraPosition = .camera(
                        MapCamera(centerCoordinate: coordinate, distance: 1000)
                    )
                    selectedCoordinate = coordinate
                }
            } catch {
                print("Search error: \(error.localizedDescription)")
            }

            searchText = ""
            isSearching = false
            searchCompleter.clear()
            isSearchFieldFocused = false
        }
    }
}

// MARK: - Preview
#Preview {
    LocationPickerSheetV2(
        initialCoordinate: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503),
        radius: 100
    ) { coordinate, name in
        print("Selected: \(coordinate), \(name)")
    }
}

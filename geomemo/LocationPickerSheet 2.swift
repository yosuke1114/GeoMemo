import SwiftUI
import MapKit
import Combine
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
    
    let initialCoordinate: CLLocationCoordinate2D
    let radius: Double
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
    
    init(initialCoordinate: CLLocationCoordinate2D, radius: Double, onLocationSelected: @escaping (CLLocationCoordinate2D, String) -> Void) {
        self.initialCoordinate = initialCoordinate
        self.radius = radius
        self.onLocationSelected = onLocationSelected
        _selectedCoordinate = State(initialValue: initialCoordinate)
        _cameraPosition = State(initialValue: .camera(
            MapCamera(centerCoordinate: initialCoordinate, distance: 1000)
        ))
    }
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Map
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
                
                // Bottom Sheet
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Brand.primaryText.opacity(0.1))
                        .frame(height: 1)
                    
                    VStack(spacing: 12) {
                        Text("Drag the map to select a location", comment: "location picker hint")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(Brand.primaryText.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .center)
                        
                        HStack(spacing: 12) {
                            HStack(spacing: 8) {
                                Image("ph-map-pin-fill")
                                    .resizable()
                                    .frame(width: 20, height: 20)
                                    .foregroundColor(Brand.blue)
                                
                                Text(locationName)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(Brand.primaryText)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            Button(action: {
                                onLocationSelected(selectedCoordinate, locationName)
                                dismiss()
                            }) {
                                Text("SELECT", comment: "location picker confirm")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 100, height: 44)
                                    .background(Brand.blue)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
                .frame(height: 120)
                .background(Brand.surface)
            }
            .ignoresSafeArea()
            
            // Search Bar Overlay
            VStack {
                // サーチバー + キャンセル（1行）
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image("ph-magnifying-glass")
                            .resizable()
                            .frame(width: 16, height: 16)
                            .foregroundColor(Brand.primaryText.opacity(0.5))

                        TextField(String(localized: "Search places..."), text: $searchText)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(Brand.primaryText)
                            .focused($isSearchFieldFocused)
                            .onChange(of: searchText) { _, newValue in
                                if newValue.isEmpty {
                                    isSearching = false
                                    searchCompleter.clear()
                                } else {
                                    isSearching = true
                                    searchCompleter.update(
                                        query: newValue,
                                        region: MKCoordinateRegion(
                                            center: selectedCoordinate,
                                            span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
                                        )
                                    )
                                }
                            }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Brand.surface)
                    .cornerRadius(8)

                    Button(action: { dismiss() }) {
                        Text("Cancel")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Brand.primaryText)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 60)
                
                // Search Results List
                if isSearching && !searchCompleter.completions.isEmpty {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(searchCompleter.completions, id: \.self) { completion in
                                Button(action: {
                                    selectCompletion(completion)
                                }) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(completion.title)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(Brand.primaryText)
                                        
                                        if !completion.subtitle.isEmpty {
                                            Text(completion.subtitle)
                                                .font(.system(size: 13, weight: .regular))
                                                .foregroundColor(Brand.primaryText.opacity(0.6))
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                }
                                
                                if completion != searchCompleter.completions.last {
                                    Rectangle()
                                        .fill(Brand.primaryText.opacity(0.1))
                                        .frame(height: 1)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    .background(Brand.surface)
                    .cornerRadius(8)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                
                Spacer()
            }
        }
        .onAppear {
            reverseGeocode(coordinate: selectedCoordinate)
        }
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

import SwiftUI
import MapKit
import Combine
// Phosphor icons loaded from local Assets.xcassets

// MARK: - Brand Colors
private enum Brand {
    static let white = Color.white
    static let black = Color(hex: "1A1A1A")
    static let blue = Color(hex: "3D3BF3")
    static let lightGray = Color(hex: "F5F5F5")
}

// MARK: - Color Extension
private extension Color {
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hexSanitized.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 255, 255, 255)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

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
    @State private var locationName: String = "取得中..."
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
                                .fill(Brand.black)
                                .frame(width: 16, height: 16)
                            Circle()
                                .stroke(Brand.white, lineWidth: 3)
                                .frame(width: 16, height: 16)
                        }
                    }
                    
                    // Radius circle
                    MapCircle(center: selectedCoordinate, radius: radius)
                        .foregroundStyle(Color(.sRGB, red: 0.24, green: 0.23, blue: 0.95, opacity: 0.1))
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
                        .fill(Brand.black.opacity(0.1))
                        .frame(height: 1)
                    
                    VStack(spacing: 12) {
                        Text("マップをドラッグして場所を選択")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(Brand.black.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .center)
                        
                        HStack(spacing: 12) {
                            HStack(spacing: 8) {
                                Image("ph-map-pin-fill")
                                    .resizable()
                                    .frame(width: 20, height: 20)
                                    .foregroundColor(Brand.blue)
                                
                                Text(locationName)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(Brand.black)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            Button(action: {
                                onLocationSelected(selectedCoordinate, locationName)
                                dismiss()
                            }) {
                                Text("SELECT")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Brand.white)
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
                .background(Brand.white)
            }
            .ignoresSafeArea()
            
            // Search Bar Overlay
            VStack {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image("ph-magnifying-glass")
                            .resizable()
                            .frame(width: 16, height: 16)
                            .foregroundColor(Brand.black.opacity(0.5))
                        
                        TextField("場所を検索...", text: $searchText)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(Brand.black)
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Brand.white)
                    .cornerRadius(8)
                    
                    Button(action: { dismiss() }) {
                        Text("CANCEL")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(Brand.black)
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
                                            .foregroundColor(Brand.black)
                                        
                                        if !completion.subtitle.isEmpty {
                                            Text(completion.subtitle)
                                                .font(.system(size: 13, weight: .regular))
                                                .foregroundColor(Brand.black.opacity(0.6))
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                }
                                
                                if completion != searchCompleter.completions.last {
                                    Rectangle()
                                        .fill(Brand.black.opacity(0.1))
                                        .frame(height: 1)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    .background(Brand.white)
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
            let geocoder = CLGeocoder()
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                if let placemark = placemarks.first {
                    if let locality = placemark.locality {
                        if let subLocality = placemark.subLocality {
                            locationName = "\(subLocality), \(locality)"
                        } else {
                            locationName = locality
                        }
                    } else if let administrativeArea = placemark.administrativeArea {
                        locationName = administrativeArea
                    } else if let name = placemark.name {
                        locationName = name
                    } else {
                        locationName = "Unknown Location"
                    }
                } else {
                    locationName = "Unknown Location"
                }
            } catch {
                locationName = "Unknown Location"
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
                    let coordinate = item.placemark.coordinate
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

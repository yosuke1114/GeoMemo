import SwiftUI
import SwiftData
import CoreLocation
import MapKit

struct WatchQuickAddView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.watchStoreStatus) private var storeStatus
    @State private var locationHelper = QuickAddLocationHelper()
    @State private var title = ""
    @State private var selectedColorIndex = 0
    @State private var isSaving = false
    @State private var showSaved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if !storeStatus.isPersistent {
                        WatchNotSavedBanner()
                    }

                    // Title input
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)

                    // Location status
                    HStack(spacing: 4) {
                        Image(systemName: locationHelper.locationName != nil ? "mappin.circle.fill" : "location.fill")
                            .font(.caption2)
                            .foregroundStyle(WatchBrand.blue)

                        if let name = locationHelper.locationName {
                            Text(name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("Getting location...")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Color selector
                    HStack(spacing: 6) {
                        ForEach(WatchMemoColor.allCases, id: \.rawValue) { memoColor in
                            Circle()
                                .fill(memoColor.color)
                                .frame(width: 22, height: 22)
                                .overlay {
                                    if selectedColorIndex == memoColor.rawValue {
                                        Circle()
                                            .stroke(Color.white, lineWidth: 2)
                                    }
                                }
                                .onTapGesture {
                                    selectedColorIndex = memoColor.rawValue
                                }
                        }
                    }

                    // Save button
                    Button {
                        saveMemo()
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Save")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(WatchBrand.blue)
                    .disabled(!canSave)

                    if showSaved {
                        HStack {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                            Text("Saved!")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("Add Memo")
        }
        .onAppear {
            locationHelper.requestLocation()
        }
    }

    /// 保存されない状態のときは作らせない。
    ///
    /// 無料版のメモ数の上限（`MemoLimitPolicy`）は Watch では掛けない。Watch は Pro かどうかを知る手段が
    /// なく（StoreKit の状態を同期していない）、掛けると Pro の人まで 5 件に制限してしまうため。
    /// Pro 状態を Watch に同期できたら `MemoLimitPolicy.isAtLimit` を使う（別 PR）。
    private var canSave: Bool {
        storeStatus.isPersistent && !title.isEmpty && locationHelper.coordinate != nil && !isSaving
    }

    private func saveMemo() {
        guard canSave, let coordinate = locationHelper.coordinate else { return }
        isSaving = true

        let memo = GeoMemo(
            title: title,
            note: "",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radius: 100.0,
            locationName: locationHelper.locationName ?? "",
            colorIndex: selectedColorIndex
        )

        modelContext.insert(memo)
        try? modelContext.save()

        // Reset form
        title = ""
        selectedColorIndex = 0
        isSaving = false

        withAnimation {
            showSaved = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showSaved = false
            }
        }
    }
}

// MARK: - Quick Add Location Helper

@Observable
class QuickAddLocationHelper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var coordinate: CLLocationCoordinate2D?
    var locationName: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocation() {
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        coordinate = location.coordinate

        // CLGeocoder は watchOS 26 で deprecated。iOS 側（MemoEditorView 等）と同じく
        // MapKit の MKReverseGeocodingRequest に統一する。
        guard let request = MKReverseGeocodingRequest(location: location) else { return }
        Task { [weak self] in
            guard let item = try? await request.mapItems.first else { return }
            let repr = item.addressRepresentations
            let name = [repr?.cityWithContext, repr?.cityName, repr?.regionName, item.name]
                .compactMap { $0 }
                .first { !$0.isEmpty } ?? ""
            self?.locationName = name
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}

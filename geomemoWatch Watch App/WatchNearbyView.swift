import SwiftUI
import SwiftData
import CoreLocation

struct WatchNearbyView: View {
    @Query(sort: \GeoMemo.createdAt, order: .reverse) private var memos: [GeoMemo]
    @State private var locationHelper = WatchLocationHelper()

    var nearbyMemos: [(memo: GeoMemo, distance: Double)] {
        guard let userLocation = locationHelper.currentLocation else { return [] }
        return memos
            .map { memo in
                let memoLocation = CLLocation(latitude: memo.latitude, longitude: memo.longitude)
                let distance = userLocation.distance(from: memoLocation)
                return (memo: memo, distance: distance)
            }
            .filter { $0.distance <= 1000 }
            .sorted { $0.distance < $1.distance }
    }

    var body: some View {
        NavigationStack {
            Group {
                if locationHelper.currentLocation == nil {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Getting location...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if nearbyMemos.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "location.slash")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No memos nearby")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Within 1km range")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    List(nearbyMemos, id: \.memo.id) { item in
                        NavigationLink(value: item.memo.id) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(WatchMemoColor.color(for: item.memo.colorIndex))
                                    .frame(width: 10, height: 10)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.memo.title.isEmpty ? String(localized: "Untitled") : item.memo.title)
                                        .font(.headline)
                                        .lineLimit(1)

                                    Text(item.memo.locationName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Text(formatDistance(item.distance))
                                    .font(.caption2)
                                    .foregroundStyle(WatchBrand.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Nearby")
            .navigationDestination(for: UUID.self) { id in
                if let memo = memos.first(where: { $0.id == id }) {
                    WatchMemoDetailView(memo: memo)
                }
            }
        }
        .onAppear {
            locationHelper.requestLocation()
        }
    }

    private func formatDistance(_ distance: Double) -> String {
        if distance < 1000 {
            return "\(Int(distance))m"
        } else {
            return String(format: "%.1fkm", distance / 1000)
        }
    }
}

// MARK: - Watch Location Helper

@Observable
class WatchLocationHelper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var currentLocation: CLLocation?

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
        currentLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}

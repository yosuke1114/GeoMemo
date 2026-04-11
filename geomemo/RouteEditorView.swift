import SwiftUI
import MapKit

// MARK: - RouteEditorView
// マップ上でウェイポイントをタップ追加し、ルートを編集するシート
struct RouteEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var waypoints: [RouteWaypoint]

    @State private var cameraPosition: MapCameraPosition
    @State private var pending: [RouteWaypoint]

    private let maxWaypoints = 5

    init(waypoints: Binding<[RouteWaypoint]>, initialCoordinate: CLLocationCoordinate2D) {
        _waypoints = waypoints
        let initial = waypoints.wrappedValue
        _pending = State(initialValue: initial)

        if initial.count >= 2 {
            // カメラをウェイポイント全体に合わせる
            let region = MKCoordinateRegion.fitting(coordinates: initial.map { $0.coordinate })
            _cameraPosition = State(initialValue: .region(region))
        } else if let first = initial.first {
            _cameraPosition = State(initialValue: .camera(
                MapCamera(centerCoordinate: first.coordinate, distance: 1000)
            ))
        } else {
            _cameraPosition = State(initialValue: .camera(
                MapCamera(centerCoordinate: initialCoordinate, distance: 1000)
            ))
        }
    }

    var body: some View {
        ZStack {
            // MARK: Map
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    // ウェイポイント間のライン
                    if pending.count >= 2 {
                        MapPolyline(coordinates: pending.map { $0.coordinate })
                            .stroke(Brand.blue.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
                    }

                    // ウェイポイントピン
                    ForEach(Array(pending.enumerated()), id: \.element.id) { index, wp in
                        Annotation("", coordinate: wp.coordinate) {
                            waypointPin(number: index + 1)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onTapGesture { screenPoint in
                    guard pending.count < maxWaypoints else { return }
                    if let coord = proxy.convert(screenPoint, from: .local) {
                        addWaypoint(at: coord)
                    }
                }
            }

            // MARK: UI Overlay
            VStack(spacing: 0) {
                // ナビバー
                HStack {
                    Button(String(localized: "CANCEL")) { dismiss() }
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(Brand.primaryText)

                    Spacer()

                    Text("ROUTE")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Brand.primaryText)

                    Spacer()

                    Button(String(localized: "DONE")) {
                        waypoints = pending
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Brand.blue)
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)
                .padding(.bottom, 16)
                .background(.ultraThinMaterial)

                // ヒントバナー
                if pending.isEmpty {
                    Text(String(localized: "Tap the map to add waypoints (max 5)"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.55))
                        .cornerRadius(10)
                        .padding(.top, 12)
                } else if pending.count >= maxWaypoints {
                    Text(String(localized: "Maximum 5 waypoints reached"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.8))
                        .cornerRadius(10)
                        .padding(.top, 12)
                }

                Spacer()

                // ウェイポイントリスト
                if !pending.isEmpty {
                    waypointList
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Waypoint Pin
    private func waypointPin(number: Int) -> some View {
        ZStack {
            Circle()
                .fill(Brand.blue)
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
        }
    }

    // MARK: - Waypoint List
    private var waypointList: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Brand.primaryText.opacity(0.1))
                .frame(height: 1)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(pending.enumerated()), id: \.element.id) { index, wp in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Brand.blue)
                                    .frame(width: 26, height: 26)
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(wp.name.isEmpty
                                    ? String(format: String(localized: "Waypoint %d"), index + 1)
                                    : wp.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(Brand.primaryText)
                                    .lineLimit(1)
                                Text(String(format: "%.4f, %.4f", wp.latitude, wp.longitude))
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundColor(Brand.tertiaryText)
                            }

                            Spacer()

                            Button(action: { removeWaypoint(at: index) }) {
                                Image("ph-x-circle-fill")
                                    .resizable()
                                    .frame(width: 20, height: 20)
                                    .foregroundColor(Brand.secondaryText)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)

                        if index < pending.count - 1 {
                            Rectangle()
                                .fill(Brand.primaryText.opacity(0.08))
                                .frame(height: 1)
                                .padding(.leading, 58)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .background(Brand.surface)
    }

    // MARK: - Actions
    private func addWaypoint(at coordinate: CLLocationCoordinate2D) {
        HapticManager.impact(.light)
        let wp = RouteWaypoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
        pending.append(wp)

        // 逆ジオコーディングで名前を取得
        let wpID = wp.id
        Task {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let request = MKReverseGeocodingRequest(location: location),
               let item = try? await request.mapItems.first {
                let repr = item.addressRepresentations
                let name = repr?.cityWithContext ?? repr?.cityName ?? repr?.regionName ?? item.name ?? ""
                if let idx = pending.firstIndex(where: { $0.id == wpID }) {
                    pending[idx].name = name
                }
            }
        }
    }

    private func removeWaypoint(at index: Int) {
        HapticManager.impact(.light)
        pending.remove(at: index)
    }
}

// MARK: - MKCoordinateRegion Helper
private extension MKCoordinateRegion {
    static func fitting(coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }
        let minLat = coordinates.map { $0.latitude }.min()!
        let maxLat = coordinates.map { $0.latitude }.max()!
        let minLon = coordinates.map { $0.longitude }.min()!
        let maxLon = coordinates.map { $0.longitude }.max()!
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.01),
            longitudeDelta: max((maxLon - minLon) * 1.5, 0.01)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

// MARK: - Preview
#Preview {
    @Previewable @State var waypoints: [RouteWaypoint] = []
    RouteEditorView(
        waypoints: $waypoints,
        initialCoordinate: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
    )
}

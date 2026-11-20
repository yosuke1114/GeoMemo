import SwiftUI
import MapKit

// メモの作成・編集画面の「基本」(場所・範囲・題・到着／退出) の部品。
// 「文章でメモを作る」の確認画面でも、そのまま同じ部品を使えるよう、状態は Binding と値で受け取る。

// MARK: - 基本

/// 基本の項目 (地図と範囲、題、到着／退出)。これだけで保存できる。
struct MemoBasicsSection: View {
    @Binding var title: String
    @Binding var radius: Double
    @Binding var notifyOnEntry: Bool
    @Binding var notifyOnExit: Bool
    /// スライダーの上限 (開いた時点の値に合わせる)。
    var radiusCeiling: Double = RadiusPolicy.maximum

    let coordinate: CLLocationCoordinate2D
    /// 地図の左下のバッジに出す文字 (場所名、またはルートの案内)。
    let locationBadgeText: String
    var isRouteTrigger: Bool = false
    var routeWaypoints: [RouteWaypoint] = []
    let onTapLocation: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RadiusMapPreview(
                coordinate: coordinate,
                radius: radius,
                isRouteTrigger: isRouteTrigger,
                routeWaypoints: routeWaypoints,
                badgeText: locationBadgeText,
                onTapLocation: onTapLocation
            )

            TextField("Title", text: $title)
                .font(.title3.weight(.semibold))
                .foregroundColor(Brand.primaryText)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Brand.background)
                .accessibilityIdentifier("editorTitleField")

            MemoDivider()

            RadiusAdjuster(radius: $radius, ceiling: radiusCeiling)

            if !isRouteTrigger {
                MemoDivider()
                MemoToggleRow(title: "ON ENTRY", isOn: $notifyOnEntry)
                    .accessibilityIdentifier("editorNotifyEntry")
                MemoToggleRow(title: "ON EXIT", isOn: $notifyOnExit)
                    .accessibilityIdentifier("editorNotifyExit")
            }
        }
    }
}

struct MemoDivider: View {
    var body: some View {
        Divider().background(Brand.primaryText.opacity(0.1))
    }
}

struct MemoToggleRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundColor(Brand.primaryText)
        }
        .tint(Brand.blue)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - 地図 (円つき)

/// 場所と範囲の円を表示する地図。範囲が変わっても拡大率は段階的にしか変えない (円の大きさの変化が見えるように)。
struct RadiusMapPreview: View {
    @AppStorage("mapStyle") private var mapStyleRaw: String = GeoMapStyle.mono.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let coordinate: CLLocationCoordinate2D
    let radius: Double
    var isRouteTrigger: Bool = false
    var routeWaypoints: [RouteWaypoint] = []
    let badgeText: String
    let onTapLocation: () -> Void

    @State private var cameraPosition: MapCameraPosition

    init(coordinate: CLLocationCoordinate2D, radius: Double, isRouteTrigger: Bool = false,
         routeWaypoints: [RouteWaypoint] = [], badgeText: String, onTapLocation: @escaping () -> Void) {
        self.coordinate = coordinate
        self.radius = radius
        self.isRouteTrigger = isRouteTrigger
        self.routeWaypoints = routeWaypoints
        self.badgeText = badgeText
        self.onTapLocation = onTapLocation
        _cameraPosition = State(initialValue: Self.camera(
            coordinate: coordinate, radius: radius, isRouteTrigger: isRouteTrigger, waypoints: routeWaypoints))
    }

    /// 地図の向きが変わる条件。範囲は「段」が変わったときだけ見る。
    private struct CameraKey: Equatable {
        var latitude: Double
        var longitude: Double
        var span: Double
        var routePoints: Int
        var isRoute: Bool
        /// 経由地の外接範囲。経由地を動かしたら地図が追従する。
        var minLat: Double
        var maxLat: Double
        var minLon: Double
        var maxLon: Double
    }

    private var cameraKey: CameraKey {
        let useRoute = isRouteTrigger && routeWaypoints.count >= 2
        let lats = routeWaypoints.map(\.latitude), lons = routeWaypoints.map(\.longitude)
        return CameraKey(latitude: coordinate.latitude, longitude: coordinate.longitude,
                         span: RadiusPolicy.mapSpanMeters(for: radius),
                         routePoints: routeWaypoints.count, isRoute: isRouteTrigger,
                         minLat: useRoute ? (lats.min() ?? 0) : 0, maxLat: useRoute ? (lats.max() ?? 0) : 0,
                         minLon: useRoute ? (lons.min() ?? 0) : 0, maxLon: useRoute ? (lons.max() ?? 0) : 0)
    }

    private static func camera(coordinate: CLLocationCoordinate2D, radius: Double,
                               isRouteTrigger: Bool, waypoints: [RouteWaypoint]) -> MapCameraPosition {
        if isRouteTrigger, waypoints.count >= 2 {
            let lats = waypoints.map(\.latitude), lons = waypoints.map(\.longitude)
            let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
            let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
            return .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.8, 0.01),
                                       longitudeDelta: max((maxLon - minLon) * 1.8, 0.01))))
        }
        let span = RadiusPolicy.mapSpanMeters(for: radius)
        return .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: span, longitudinalMeters: span))
    }

    private var style: MapStyle {
        switch GeoMapStyle(rawValue: mapStyleRaw) ?? .mono {
        case .satellite: return .imagery
        case .detail:    return .standard(elevation: .flat, emphasis: .automatic, pointsOfInterest: .all, showsTraffic: false)
        case .transit:   return .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .including([.publicTransport]), showsTraffic: false)
        default:         return .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false)
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Map(position: $cameraPosition, interactionModes: []) {
                mapContent
            }
            .mapStyle(style)
            .grayscale((GeoMapStyle(rawValue: mapStyleRaw) ?? .mono) == .mono && colorScheme != .dark ? 1.0 : 0)
            .id(mapStyleRaw)
            .frame(height: 200)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: cameraKey) {
                let next = Self.camera(coordinate: coordinate, radius: radius,
                                       isRouteTrigger: isRouteTrigger, waypoints: routeWaypoints)
                if reduceMotion {
                    cameraPosition = next
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) { cameraPosition = next }
                }
            }

            Button {
                HapticManager.impact(.light)
                onTapLocation()
            } label: {
                HStack(spacing: 6) {
                    Image("ph-map-pin-fill")
                        .resizable()
                        .frame(width: 14, height: 14)
                        .foregroundColor(Brand.primaryText)
                    Text(badgeText)
                        .font(.caption.weight(.bold))
                        .foregroundColor(Brand.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "pencil")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Brand.primaryText.opacity(0.7))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Brand.background)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Brand.primaryText, lineWidth: 1))
            }
            .padding(.leading, 16)
            .padding(.bottom, 16)
            .accessibilityLabel(String(localized: "Change location"))
            .accessibilityValue(badgeText)
            .accessibilityIdentifier("editorLocationButton")
        }
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        if isRouteTrigger {
            if routeWaypoints.count >= 2 {
                MapPolyline(coordinates: routeWaypoints.map { $0.coordinate })
                    .stroke(Brand.blue.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
            }
            ForEach(Array(routeWaypoints.enumerated()), id: \.element.id) { index, wp in
                Annotation("", coordinate: wp.coordinate) {
                    ZStack {
                        Circle().fill(Brand.blue).frame(width: 22, height: 22)
                        Text("\(index + 1)").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                    }
                }
            }
        } else {
            Annotation("", coordinate: coordinate) {
                ZStack {
                    Circle().fill(Brand.primaryText).frame(width: 12, height: 12)
                    Circle().stroke(Brand.background, lineWidth: 2).frame(width: 12, height: 12)
                }
            }
            MapCircle(center: coordinate, radius: radius)
                .foregroundStyle(Brand.blue.opacity(0.15))
                .stroke(Brand.blue, lineWidth: 2)
        }
    }
}

// MARK: - 範囲のスライダー

struct RadiusAdjuster: View {
    @Binding var radius: Double
    /// スライダーの上限。開いた時点で決め、操作中に変わらない。
    var ceiling: Double = RadiusPolicy.maximum

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("RADIUS")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Brand.primaryText.opacity(0.5))
                Spacer()
                Text(RadiusPolicy.label(radius))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundColor(Brand.blue)
                    .accessibilityHidden(true)
            }

            Slider(
                value: Binding(
                    get: { radius },
                    set: { radius = RadiusPolicy.applyingSlider($0, to: radius, ceiling: ceiling) }
                ),
                in: RadiusPolicy.sliderRange(ceiling: ceiling),
                step: RadiusPolicy.step
            )
            .tint(Brand.blue)
            .accessibilityLabel(String(localized: "RADIUS"))
            .accessibilityValue(RadiusPolicy.spokenValue(radius))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: radius = RadiusPolicy.adjusted(radius, increment: true, ceiling: ceiling)
                case .decrement: radius = RadiusPolicy.adjusted(radius, increment: false, ceiling: ceiling)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("radiusSlider")

            // 従来の 4 択はすばやく選ぶための候補として残す。最大の文字サイズでは 2 列に折り返す。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(RadiusPolicy.presets, id: \.self) { presetButton($0) }
                }
                VStack(spacing: 8) {
                    HStack(spacing: 8) { presetButton(RadiusPolicy.presets[0]); presetButton(RadiusPolicy.presets[1]) }
                    HStack(spacing: 8) { presetButton(RadiusPolicy.presets[2]); presetButton(RadiusPolicy.presets[3]) }
                }
            }

            if RadiusPolicy.isTooSmallForIndoors(radius) {
                Label {
                    Text("Under 100 m may not trigger inside buildings.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .foregroundColor(Brand.secondaryText)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func presetButton(_ value: Double) -> some View {
        let selected = radius == value
        return Button {
            HapticManager.selection()
            radius = value
        } label: {
            Text(RadiusPolicy.label(value))
                .font(.subheadline.weight(selected ? .bold : .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundColor(selected ? Brand.blue : Brand.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? Brand.background : Brand.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Brand.blue : Color.clear, lineWidth: 1.5))
        }
        .accessibilityLabel(RadiusPolicy.spokenValue(value))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 「詳細」の開閉

/// 「詳細」の見出し。閉じているときは、設定済みの項目の要約を出して、隠れた設定に気づけるようにする。
struct AdvancedDisclosure<Content: View>: View {
    @Binding var isExpanded: Bool
    let summary: String
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stateText: String {
        isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                HapticManager.selection()
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DETAILS")
                            .font(.body.weight(.semibold))
                            .foregroundColor(Brand.primaryText)
                        if !isExpanded || !summary.isEmpty {
                            Text(summary.isEmpty
                                 ? String(localized: "Time, expiry, memo, photo, tags and more")
                                 : summary)
                                .font(.caption)
                                .foregroundColor(summary.isEmpty ? Brand.secondaryText : Brand.blue)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Brand.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "DETAILS"))
            .accessibilityValue(summary.isEmpty
                ? stateText
                : "\(stateText), \(summary)")
            .accessibilityHint(isExpanded
                ? String(localized: "Hides the detail items")
                : String(localized: "Shows the detail items"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("editorDetailsToggle")

            if isExpanded {
                MemoDivider()
                content()
            }
        }
    }
}

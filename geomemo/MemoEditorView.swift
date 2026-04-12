import SwiftUI
import SwiftData
import MapKit
// Phosphor icons loaded from local Assets.xcassets
import PhotosUI

// Brand colors and Color(hex:) are defined in Theme.swift

// MARK: - Editor Mode
enum MemoEditorMode {
    case create(coordinate: CLLocationCoordinate2D)
    case edit(GeoMemo)

    var navigationTitle: String {
        switch self {
        case .create: return String(localized: "NEW MEMO")
        case .edit:   return String(localized: "EDIT MEMO")
        }
    }

    var saveButtonLabel: String {
        switch self {
        case .create: return String(localized: "SAVE")
        case .edit:   return String(localized: "UPDATE")
        }
    }
}

// MARK: - MemoEditorView
struct MemoEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("mapStyle") private var mapStyleRaw: String = GeoMapStyle.mono.rawValue

    let mode: MemoEditorMode
    var onDelete: (() -> Void)?

    @State private var title: String
    @State private var note: String
    @State private var selectedRadius: Double
    @State private var notifyOnEntry: Bool
    @State private var notifyOnExit: Bool
    @State private var notifyOnPass: Bool
    @State private var locationName: String
    @State private var photoData: Data?
    @State private var showLocationPicker = false
    @State private var showDeleteAlert = false

    @State private var hasDeadline = false
    @State private var deadline = Date()
    @State private var hasTimeWindow = false
    @State private var timeStart = Calendar.current
        .date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
    @State private var timeEnd = Calendar.current
        .date(bySettingHour: 20, minute: 0, second: 0, of: Date())!
    @State private var hasDayFilter = false
    @State private var activeDays: Set<Int> = [1, 2, 3, 4, 5]

    @State private var selectedColorIndex: Int
    @State private var cameraPosition: MapCameraPosition
    @State private var currentCoordinate: CLLocationCoordinate2D

    // Route trigger
    @State private var isRouteTrigger: Bool = false
    @State private var routeWaypoints: [RouteWaypoint] = []
    @State private var showRouteEditor = false
    @State private var exitDelayMinutes: Int? = nil

    // Tags (Phase 2)
    @State private var selectedTags: Set<Int> = []
    @State private var customTags: [String] = []
    @State private var suggestedTags: [PresetTag] = []
    @State private var newCustomTag: String = ""
    @State private var showCustomTagInput = false
    @State private var tagSuggestTask: Task<Void, Never>? = nil

    @ObservedObject private var locationManager = LocationManager.shared

    init(mode: MemoEditorMode, onDelete: (() -> Void)? = nil) {
        self.mode = mode
        self.onDelete = onDelete

        switch mode {
        case .create(let coordinate):
            let defaults = UserDefaults.standard
            _title = State(initialValue: "")
            _note = State(initialValue: "")
            _selectedRadius = State(initialValue: defaults.object(forKey: "defaultRadius") as? Double ?? 100)
            _notifyOnEntry = State(initialValue: defaults.object(forKey: "notifyOnEntry") as? Bool ?? true)
            _notifyOnExit = State(initialValue: defaults.object(forKey: "notifyOnExit") as? Bool ?? true)
            _notifyOnPass = State(initialValue: false)
            _locationName = State(initialValue: String(localized: "Loading..."))
            _photoData = State(initialValue: nil)
            _selectedColorIndex = State(initialValue: 0)
            _currentCoordinate = State(initialValue: coordinate)
            _cameraPosition = State(initialValue: .camera(
                MapCamera(centerCoordinate: coordinate, distance: 500)
            ))

        case .edit(let memo):
            _title = State(initialValue: memo.title)
            _note = State(initialValue: memo.note)
            _selectedRadius = State(initialValue: memo.radius)
            _notifyOnEntry = State(initialValue: memo.notifyOnEntry)
            _notifyOnExit = State(initialValue: memo.notifyOnExit)
            _notifyOnPass = State(initialValue: memo.notifyOnPass)
            _locationName = State(initialValue: memo.locationName)
            _photoData = State(initialValue: memo.imageData)
            _selectedColorIndex = State(initialValue: memo.colorIndex)
            _currentCoordinate = State(initialValue: memo.coordinate)
            _cameraPosition = State(initialValue: .camera(
                MapCamera(centerCoordinate: memo.coordinate, distance: 500)
            ))

            // Trigger conditions
            _hasDeadline = State(initialValue: memo.deadline != nil)
            _deadline = State(initialValue: memo.deadline ?? Date())
            if let start = memo.timeWindowStart, let end = memo.timeWindowEnd {
                _hasTimeWindow = State(initialValue: true)
                let cal = Calendar.current
                _timeStart = State(initialValue: cal.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: Date())!)
                _timeEnd = State(initialValue: cal.date(bySettingHour: end / 60, minute: end % 60, second: 0, of: Date())!)
            }
            if let days = memo.activeDays {
                _hasDayFilter = State(initialValue: true)
                _activeDays = State(initialValue: Set(days))
            }
            _isRouteTrigger = State(initialValue: memo.isRouteTrigger)
            _routeWaypoints = State(initialValue: memo.routeWaypoints)
            _exitDelayMinutes = State(initialValue: memo.exitDelayMinutes)
            _selectedTags = State(initialValue: Set(memo.tags))
            _customTags = State(initialValue: memo.customTags)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Map Preview
                    mapSection

                    // Title Field
                    titleSection

                    Divider()
                        .background(Brand.primaryText.opacity(0.1))

                    // Memo Field
                    memoSection

                    Divider()
                        .background(Brand.primaryText.opacity(0.1))

                    // Add Photo
                    photoSection

                    Divider()
                        .background(Brand.primaryText.opacity(0.1))

                    // Radius Selector
                    radiusSection

                    Divider()
                        .background(Brand.primaryText.opacity(0.1))

                    // Color Selector
                    colorSection

                    Divider()
                        .background(Brand.primaryText.opacity(0.1))

                    // Tag Section
                    tagSection

                    Divider()
                        .background(Brand.primaryText.opacity(0.1))

                    // Notify Section
                    notifySection

                    Divider()
                        .background(Brand.primaryText.opacity(0.1))

                    // Trigger Conditions
                    triggerConditionsSection

                    // Delete Button (edit mode only)
                    if case .edit = mode {
                        deleteSection
                    }
                }
            }
            .background(Brand.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 12) {
                        Button(action: { dismiss() }) {
                            Image("ph-arrow-left-bold")
                                .resizable()
                                .frame(width: 20, height: 20)
                                .foregroundColor(Brand.primaryText)
                        }

                        Text(mode.navigationTitle)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Brand.primaryText)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        HapticManager.notification(.success)
                        saveOrUpdate()
                    }) {
                        Text(mode.saveButtonLabel)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Brand.blue)
                    }
                }
            }
            .toolbarBackground(Brand.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .onAppear {
            if case .create = mode {
                reverseGeocode()
            }
            if case .edit = mode {
                refreshSuggestions()
            }
        }
        .onChange(of: title) { refreshSuggestionsDebounced() }
        .onChange(of: locationName) { refreshSuggestionsDebounced() }
        .sheet(isPresented: $showLocationPicker) {
            LocationPickerSheetV2(
                initialCoordinate: currentCoordinate,
                radius: selectedRadius,
                onLocationSelected: { newCoordinate, newLocationName in
                    currentCoordinate = newCoordinate
                    locationName = newLocationName
                    cameraPosition = .camera(
                        MapCamera(centerCoordinate: newCoordinate, distance: 500)
                    )
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showRouteEditor) {
            RouteEditorView(
                waypoints: $routeWaypoints,
                initialCoordinate: currentCoordinate
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .alert("Delete this memo?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                HapticManager.notification(.warning)
                deleteMemo()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    // MARK: - Map Section
    private var mapSection: some View {
        ZStack(alignment: .bottomLeading) {
            Map(position: $cameraPosition, interactionModes: []) {
                mapContent
            }
            .mapStyle({
                let style = GeoMapStyle(rawValue: mapStyleRaw) ?? .mono
                switch style {
                case .satellite: return .imagery
                case .detail:    return .standard(elevation: .flat, emphasis: .automatic, pointsOfInterest: .all, showsTraffic: false)
                case .transit:   return .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .including([.publicTransport]), showsTraffic: false)
                default:         return .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false)
                }
            }())
            .grayscale({
                let style = GeoMapStyle(rawValue: mapStyleRaw) ?? .mono
                return style == .mono && colorScheme != .dark ? 1.0 : 0
            }())
            .id(mapStyleRaw)
            .frame(height: 160)
            .allowsHitTesting(false)
            .onChange(of: routeWaypoints) { _, newValue in
                guard isRouteTrigger, newValue.count >= 2 else { return }
                let coords = newValue.map { $0.coordinate }
                let minLat = coords.map { $0.latitude }.min()!
                let maxLat = coords.map { $0.latitude }.max()!
                let minLon = coords.map { $0.longitude }.min()!
                let maxLon = coords.map { $0.longitude }.max()!
                let center = CLLocationCoordinate2D(
                    latitude: (minLat + maxLat) / 2,
                    longitude: (minLon + maxLon) / 2
                )
                cameraPosition = .region(MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(
                        latitudeDelta: max((maxLat - minLat) * 1.8, 0.01),
                        longitudeDelta: max((maxLon - minLon) * 1.8, 0.01)
                    )
                ))
            }

            // Location Badge — 場所変更の唯一のタップ領域
            Button {
                HapticManager.impact(.light)
                if isRouteTrigger {
                    showRouteEditor = true
                } else {
                    showLocationPicker = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image("ph-map-pin-fill")
                        .resizable()
                        .frame(width: 14, height: 14)
                        .foregroundColor(Brand.primaryText)

                    Group {
                        if isRouteTrigger {
                            Text(routeWaypoints.isEmpty
                                ? String(localized: "TAP TO ADD ROUTE")
                                : String(format: String(localized: "%d WAYPOINTS"), routeWaypoints.count))
                        } else {
                            Text(locationName.uppercased())
                        }
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Brand.primaryText)

                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Brand.primaryText.opacity(0.7))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Brand.background)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Brand.primaryText, lineWidth: 1)
                )
            }
            .padding(.leading, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Map Content (extracted to avoid type-checker timeout)
    @MapContentBuilder
    private var mapContent: some MapContent {
        if isRouteTrigger {
            if routeWaypoints.count >= 2 {
                MapPolyline(coordinates: routeWaypoints.map { $0.coordinate })
                    .stroke(Brand.blue.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
            }
            ForEach(Array(routeWaypoints.enumerated()), id: \.element.id) { index, wp in
                Annotation("", coordinate: wp.coordinate) {
                    routePin(number: index + 1, size: 22)
                }
            }
        } else {
            Annotation("", coordinate: currentCoordinate) {
                ZStack {
                    Circle().fill(Brand.primaryText).frame(width: 12, height: 12)
                    Circle().stroke(Brand.background, lineWidth: 2).frame(width: 12, height: 12)
                }
            }
            MapCircle(center: currentCoordinate, radius: selectedRadius)
                .foregroundStyle(Brand.blue.opacity(0.15))
                .stroke(Brand.blue, lineWidth: 2)
        }
    }

    private func routePin(number: Int, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(Brand.blue).frame(width: size, height: size)
            Text("\(number)").font(.system(size: size * 0.45, weight: .bold)).foregroundColor(.white)
        }
    }

    // MARK: - Title Section
    private var titleSection: some View {
        TextField("Title", text: $title)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(Brand.primaryText)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Brand.background)
    }

    // MARK: - Memo Section
    private var memoSection: some View {
        ZStack(alignment: .topLeading) {
            if note.isEmpty {
                Text("Memo")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(Brand.tertiaryText)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
            }

            TextEditor(text: $note)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(Brand.primaryText)
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .background(Brand.background)
    }

    // MARK: - Photo Section
    // PhotoSectionView は独立した struct のため、photoData 変更時のみ再レンダリングされる
    private var photoSection: some View {
        PhotoSectionView(photoData: $photoData)
    }

    // MARK: - Radius Section
    private var radiusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RADIUS")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Brand.primaryText.opacity(0.5))
                .padding(.horizontal, 20)
                .padding(.top, 16)

            HStack(spacing: 0) {
                radiusButton(value: 50, label: "50M")
                radiusButton(value: 100, label: "100M")
                radiusButton(value: 500, label: "500M")
                radiusButton(value: 1000, label: "1KM")
            }
            .background(Brand.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func radiusButton(value: Double, label: String) -> some View {
        Button(action: {
            HapticManager.selection()
            selectedRadius = value
        }) {
            Text(label)
                .font(.system(size: 15, weight: selectedRadius == value ? .bold : .semibold))
                .foregroundColor(selectedRadius == value ? Brand.blue : Brand.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(selectedRadius == value ? Brand.background : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(2)
        }
    }

    // MARK: - Color Section
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("COLOR")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Brand.primaryText.opacity(0.5))
                .padding(.horizontal, 20)
                .padding(.top, 16)

            HStack(spacing: 16) {
                ForEach(MemoColor.allCases, id: \.rawValue) { memoColor in
                    Button(action: {
                        HapticManager.selection()
                        selectedColorIndex = memoColor.rawValue
                    }) {
                        Circle()
                            .fill(memoColor.color)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .stroke(Brand.primaryText, lineWidth: 2)
                                    .opacity(selectedColorIndex == memoColor.rawValue ? 1 : 0)
                            )
                            .overlay(
                                Circle()
                                    .stroke(Brand.background, lineWidth: 2)
                                    .padding(2)
                                    .opacity(selectedColorIndex == memoColor.rawValue ? 1 : 0)
                            )
                    }
                    .accessibilityLabel(memoColor.accessibilityName)
                    .accessibilityAddTraits(selectedColorIndex == memoColor.rawValue ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Tag Section
    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TAGS")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Brand.primaryText.opacity(0.5))
                Spacer()
                Button(action: {
                    HapticManager.selection()
                    refreshSuggestions()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13))
                        Text(String(localized: "AI提案"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Brand.blue)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // プリセットタグ グリッド
            let columns = [GridItem(.adaptive(minimum: 80), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(PresetTag.allCases) { tag in
                    let isSelected = selectedTags.contains(tag.rawValue)
                    let isSuggested = !isSelected && suggestedTags.contains(where: { $0.rawValue == tag.rawValue })
                    PresetTagChip(
                        tag: tag,
                        isSelected: isSelected,
                        isSuggested: isSuggested,
                        onTap: {
                            HapticManager.selection()
                            if isSelected {
                                selectedTags.remove(tag.rawValue)
                            } else {
                                selectedTags.insert(tag.rawValue)
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 20)

            // カスタムタグ
            if !customTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(customTags, id: \.self) { tag in
                            TagChip(
                                label: tag,
                                iconName: nil,
                                isSelected: true,
                                isSuggested: false,
                                onTap: {
                                    HapticManager.selection()
                                    customTags.removeAll { $0 == tag }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }

            // カスタムタグ入力
            if showCustomTagInput {
                HStack(spacing: 8) {
                    TextField(String(localized: "タグを入力…"), text: $newCustomTag)
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.primaryText)
                        .submitLabel(.done)
                        .onSubmit { addCustomTag() }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Brand.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button(action: addCustomTag) {
                        Text(String(localized: "追加"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Brand.blue)
                    }
                }
                .padding(.horizontal, 20)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if customTags.count < GeoMemoLimits.maxCustomTags {
                Button(action: {
                    HapticManager.selection()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showCustomTagInput.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: showCustomTagInput ? "minus.circle" : "plus.circle")
                            .font(.system(size: 14))
                        Text(showCustomTagInput
                             ? String(localized: "キャンセル")
                             : String(localized: "カスタムタグを追加"))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Brand.primaryText.opacity(0.6))
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 16)
        .animation(.easeInOut(duration: 0.2), value: showCustomTagInput)
        .animation(.easeInOut(duration: 0.2), value: customTags.count)
    }

    private func addCustomTag() {
        let trimmed = newCustomTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= GeoMemoLimits.maxCustomTagLength,
              !customTags.contains(trimmed),
              customTags.count < GeoMemoLimits.maxCustomTags else { return }
        HapticManager.selection()
        customTags.append(trimmed)
        newCustomTag = ""
        showCustomTagInput = false
    }

    private func refreshSuggestions() {
        let suggestions = AutoTagEngine.suggest(title: title, note: note, locationName: locationName)
        suggestedTags = suggestions.filter { !selectedTags.contains($0.rawValue) }
    }

    private func refreshSuggestionsDebounced() {
        tagSuggestTask?.cancel()
        tagSuggestTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { refreshSuggestions() }
        }
    }

    // MARK: - Notify Section
    private var notifySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NOTIFICATIONS")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Brand.primaryText.opacity(0.5))
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // ROUTE TRIGGER
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ROUTE TRIGGER")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Brand.primaryText)
                    Text(String(localized: "Notify when passing waypoints"))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(Brand.secondaryText)
                }
                Spacer()
                Toggle("", isOn: $isRouteTrigger)
                    .labelsHidden()
                    .tint(Brand.blue)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if isRouteTrigger {
                Divider()
                    .background(Brand.primaryText.opacity(0.1))
                    .padding(.horizontal, 20)

                Button(action: { showRouteEditor = true }) {
                    HStack {
                        Image("ph-map-trifold")
                            .resizable()
                            .frame(width: 18, height: 18)
                            .foregroundColor(Brand.blue)
                        Text(routeWaypoints.isEmpty
                            ? String(localized: "ADD WAYPOINTS")
                            : String(format: String(localized: "%d WAYPOINTS — EDIT"), routeWaypoints.count))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Brand.blue)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Brand.secondaryText)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Divider()
                    .background(Brand.primaryText.opacity(0.1))
                    .padding(.horizontal, 20)

                // ON ENTRY
                HStack {
                    Text("ON ENTRY")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Brand.primaryText)
                    Spacer()
                    Toggle("", isOn: $notifyOnEntry)
                        .labelsHidden()
                        .tint(Brand.blue)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider()
                    .background(Brand.primaryText.opacity(0.1))
                    .padding(.horizontal, 20)

                // ON EXIT
                HStack {
                    Text("ON EXIT")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Brand.primaryText)
                    Spacer()
                    Toggle("", isOn: $notifyOnExit)
                        .labelsHidden()
                        .tint(Brand.blue)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                if notifyOnExit {
                    Divider()
                        .background(Brand.primaryText.opacity(0.1))
                        .padding(.horizontal, 20)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("EXIT DELAY")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(Brand.primaryText)
                            Text(String(localized: "Notify after leaving the area"))
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(Brand.secondaryText)
                        }
                        Spacer()
                        Picker("", selection: $exitDelayMinutes) {
                            Text("Immediately").tag(nil as Int?)
                            Text("5 min").tag(5 as Int?)
                            Text("15 min").tag(15 as Int?)
                            Text("30 min").tag(30 as Int?)
                            Text("1 hour").tag(60 as Int?)
                        }
                        .pickerStyle(.menu)
                        .tint(Brand.blue)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // PASS-THROUGH (v1.1)
                Divider()
                    .background(Brand.primaryText.opacity(0.1))
                    .padding(.horizontal, 20)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PASS-THROUGH")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Brand.primaryText)
                        Text(String(localized: "Show in Dynamic Island when nearby"))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(Brand.secondaryText)
                    }
                    Spacer()
                    Toggle("", isOn: $notifyOnPass)
                        .labelsHidden()
                        .tint(Brand.blue)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isRouteTrigger)
        .animation(.easeInOut(duration: 0.2), value: notifyOnExit)
    }

    // MARK: - Trigger Conditions Section
    private var triggerConditionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TRIGGER CONDITIONS")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Brand.primaryText.opacity(0.5))
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // 期限 (EXPIRY)
            HStack {
                Text("EXPIRY")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Brand.primaryText)
                Spacer()
                Toggle("", isOn: $hasDeadline)
                    .labelsHidden()
                    .tint(Brand.blue)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if hasDeadline {
                DatePicker(
                    "",
                    selection: $deadline,
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .environment(\.locale, .autoupdatingCurrent)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
                .background(Brand.primaryText.opacity(0.1))
                .padding(.horizontal, 20)

            // 時間帯 (TIME)
            HStack {
                Text("TIME WINDOW")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Brand.primaryText)
                Spacer()
                Toggle("", isOn: $hasTimeWindow)
                    .labelsHidden()
                    .tint(Brand.blue)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if hasTimeWindow {
                HStack {
                    DatePicker("", selection: $timeStart,
                        displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .environment(\.locale, .autoupdatingCurrent)
                    Text("〜")
                        .foregroundColor(Brand.primaryText.opacity(0.5))
                    DatePicker("", selection: $timeEnd,
                        displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .environment(\.locale, .autoupdatingCurrent)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
                .background(Brand.primaryText.opacity(0.1))
                .padding(.horizontal, 20)

            // 曜日 (DAYS)
            HStack {
                Text("DAYS")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Brand.primaryText)
                Spacer()
                Toggle("", isOn: $hasDayFilter)
                    .labelsHidden()
                    .tint(Brand.blue)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if hasDayFilter {
                HStack(spacing: 8) {
                    ForEach([
                        (1, String(localized: "Mon"), String(localized: "Monday")),
                        (2, String(localized: "Tue"), String(localized: "Tuesday")),
                        (3, String(localized: "Wed"), String(localized: "Wednesday")),
                        (4, String(localized: "Thu"), String(localized: "Thursday")),
                        (5, String(localized: "Fri"), String(localized: "Friday")),
                        (6, String(localized: "Sat"), String(localized: "Saturday")),
                        (0, String(localized: "Sun"), String(localized: "Sunday"))
                    ], id: \.0) { day, label, fullName in
                        Button(label) {
                            HapticManager.selection()
                            if activeDays.contains(day) {
                                activeDays.remove(day)
                            } else {
                                activeDays.insert(day)
                            }
                        }
                        .accessibilityLabel(fullName)
                        .accessibilityAddTraits(activeDays.contains(day) ? .isSelected : [])
                        .frame(width: 36, height: 36)
                        .background(
                            activeDays.contains(day)
                                ? Brand.blue
                                : Brand.secondaryBackground
                        )
                        .foregroundColor(
                            activeDays.contains(day)
                                ? .white
                                : Brand.primaryText
                        )
                        .cornerRadius(8)
                        .font(.system(size: 13, weight: .medium))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: hasDeadline)
        .animation(.easeInOut(duration: 0.25), value: hasTimeWindow)
        .animation(.easeInOut(duration: 0.25), value: hasDayFilter)
        .padding(.bottom, 40)
    }

    // MARK: - Delete Section (edit mode only)
    private var deleteSection: some View {
        Button(action: { showDeleteAlert = true }) {
            Text("DELETE MEMO")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.red)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 24)
        .padding(.bottom, 40)
    }

    // MARK: - Save or Update
    private func saveOrUpdate() {
        switch mode {
        case .create:
            let cal = Calendar.current
            let routeCoord = isRouteTrigger ? (routeWaypoints.first?.coordinate ?? currentCoordinate) : currentCoordinate
            let newMemo = GeoMemo(
                title: title,
                note: note,
                latitude: routeCoord.latitude,
                longitude: routeCoord.longitude,
                radius: selectedRadius,
                locationName: locationName,
                imageData: photoData,
                notifyOnEntry: isRouteTrigger ? true : notifyOnEntry,
                notifyOnExit: isRouteTrigger ? false : notifyOnExit,
                exitDelayMinutes: (isRouteTrigger || !notifyOnExit) ? nil : exitDelayMinutes,
                deadline: hasDeadline ? deadline : nil,
                timeWindowStart: hasTimeWindow
                    ? cal.component(.hour, from: timeStart) * 60 + cal.component(.minute, from: timeStart)
                    : nil,
                timeWindowEnd: hasTimeWindow
                    ? cal.component(.hour, from: timeEnd) * 60 + cal.component(.minute, from: timeEnd)
                    : nil,
                activeDays: hasDayFilter ? Array(activeDays) : nil,
                colorIndex: selectedColorIndex,
                isRouteTrigger: isRouteTrigger,
                waypointData: isRouteTrigger ? (try? JSONEncoder().encode(routeWaypoints)) : nil,
                tags: Array(selectedTags),
                customTags: customTags
            )
            newMemo.notifyOnPass = isRouteTrigger ? false : notifyOnPass
            modelContext.insert(newMemo)
            if isRouteTrigger {
                locationManager.startMonitoringRoute(for: newMemo)
            } else {
                registerGeofencing(for: newMemo)
            }

        case .edit(let memo):
            let cal = Calendar.current

            // Stop existing geofencing (both normal and route)
            locationManager.stopMonitoring(memoID: memo.id.uuidString)
            locationManager.stopMonitoringRoute(memoID: memo.id.uuidString)

            // Update SwiftData object
            let routeCoord = isRouteTrigger ? (routeWaypoints.first?.coordinate ?? currentCoordinate) : currentCoordinate
            memo.title = title
            memo.note = note
            memo.latitude = routeCoord.latitude
            memo.longitude = routeCoord.longitude
            memo.radius = selectedRadius
            memo.locationName = locationName
            memo.imageData = photoData
            memo.notifyOnEntry = isRouteTrigger ? true : notifyOnEntry
            memo.notifyOnExit = isRouteTrigger ? false : notifyOnExit
            memo.exitDelayMinutes = (isRouteTrigger || !notifyOnExit) ? nil : exitDelayMinutes
            memo.deadline = hasDeadline ? deadline : nil
            memo.timeWindowStart = hasTimeWindow
                ? cal.component(.hour, from: timeStart) * 60 + cal.component(.minute, from: timeStart)
                : nil
            memo.timeWindowEnd = hasTimeWindow
                ? cal.component(.hour, from: timeEnd) * 60 + cal.component(.minute, from: timeEnd)
                : nil
            memo.activeDays = hasDayFilter ? Array(activeDays) : nil
            memo.colorIndex = selectedColorIndex
            memo.isRouteTrigger = isRouteTrigger
            memo.waypointData = isRouteTrigger ? (try? JSONEncoder().encode(routeWaypoints)) : nil
            memo.tags = Array(selectedTags)
            memo.customTags = customTags
            memo.notifyOnPass = isRouteTrigger ? false : notifyOnPass

            // Re-register geofencing
            if isRouteTrigger {
                locationManager.startMonitoringRoute(for: memo)
            } else {
                registerGeofencing(for: memo)
            }
        }

        geomemoApp.indexAllMemosInSpotlight()
        dismiss()
    }

    // MARK: - Delete Memo
    private func deleteMemo() {
        guard case .edit(let memo) = mode else { return }

        // Stop geofencing
        locationManager.stopMonitoring(memoID: memo.id.uuidString)

        // Delete from SwiftData
        modelContext.delete(memo)
        geomemoApp.indexAllMemosInSpotlight()

        // Dismiss editor, then tell detail view to dismiss too
        dismiss()
        onDelete?()
    }

    // MARK: - Register Geofencing
    private func registerGeofencing(for memo: GeoMemo) {
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(
                latitude: memo.latitude,
                longitude: memo.longitude
            ),
            radius: memo.radius,
            identifier: memo.id.uuidString
        )
        region.notifyOnEntry = memo.notifyOnEntry
        region.notifyOnExit = memo.notifyOnExit
        locationManager.startMonitoring(region: region)
    }

    // MARK: - Reverse Geocoding
    private func reverseGeocode() {
        Task {
            let location = CLLocation(latitude: currentCoordinate.latitude, longitude: currentCoordinate.longitude)
            guard let request = MKReverseGeocodingRequest(location: location) else {
                locationName = String(localized: "Unknown Location")
                return
            }
            do {
                let items = try await request.mapItems
                locationName = Self.locationName(from: items.first)
            } catch {
                locationName = String(localized: "Unknown Location")
            }
        }
    }

    private static func locationName(from item: MKMapItem?) -> String {
        guard let item else { return String(localized: "Unknown Location") }
        let repr = item.addressRepresentations
        if let city = repr?.cityWithContext, !city.isEmpty { return city }
        if let city = repr?.cityName, !city.isEmpty { return city }
        if let region = repr?.regionName, !region.isEmpty { return region }
        return item.name ?? String(localized: "Unknown Location")
    }
}

// MARK: - PhotoSectionView
/// MemoEditorView の body から切り出すことで、UIImage デコードが他の @State 変化時に走らなくなる。
private struct PhotoSectionView: View {
    @Binding var photoData: Data?
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                HStack(spacing: 10) {
                    Image("ph-camera-fill")
                        .resizable()
                        .frame(width: 20, height: 20)
                        .foregroundColor(Brand.blue)

                    Text("ADD PHOTO")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Brand.blue)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .onChange(of: selectedPhoto) { _, newValue in
                Task {
                    if let data = try? await newValue?.loadTransferable(type: Data.self) {
                        photoData = data
                    }
                }
            }

            if let data = photoData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Preview
#Preview("Create") {
    MemoEditorView(mode: .create(coordinate: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)))
        .modelContainer(for: GeoMemo.self, inMemory: true)
}

#Preview("Edit") {
    MemoEditorView(mode: .edit(GeoMemo(
        title: "Corner Coffee Thoughts",
        note: "The way the light hits the brick wall at 8:45am.",
        latitude: 35.6585,
        longitude: 139.7454,
        radius: 100,
        locationName: "SHIBUYA, TOKYO"
    )))
    .modelContainer(for: GeoMemo.self, inMemory: true)
}

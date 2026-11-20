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
    @State private var showDetails = false
    /// スライダーの上限。開いた時点の値で決める (1000m 超で保存された値も、触ったあと戻せる)。
    private let radiusCeiling: Double
    @State private var currentCoordinate: CLLocationCoordinate2D

    // Route trigger
    @State private var isRouteTrigger: Bool = false
    @State private var routeWaypoints: [RouteWaypoint] = []
    @State private var showRouteEditor = false
    @State private var exitDelayMinutes: Int? = nil
    @State private var dwellMinutes: Int? = nil

    // List / Checklist mode (v1.2)
    @State private var isListMode: Bool
    @State private var listItems: [ListItem]

    // Tags (Phase 2)
    @State private var selectedTags: Set<Int> = []
    @State private var customTags: [String] = []

    @ObservedObject private var locationManager = LocationManager.shared
    @State private var showProPaywall = false

    init(mode: MemoEditorMode, onDelete: (() -> Void)? = nil) {
        self.mode = mode
        self.onDelete = onDelete
        if case .edit(let memo) = mode {
            radiusCeiling = RadiusPolicy.ceiling(forOriginal: memo.radius)
        } else {
            radiusCeiling = RadiusPolicy.maximum
        }

        switch mode {
        case .create(let coordinate):
            let defaults = UserDefaults.standard
            _title = State(initialValue: "")
            _note = State(initialValue: "")
            _selectedRadius = State(initialValue: RadiusPolicy.clamp(defaults.object(forKey: "defaultRadius") as? Double ?? RadiusPolicy.defaultValue))
            _notifyOnEntry = State(initialValue: defaults.object(forKey: "notifyOnEntry") as? Bool ?? true)
            _notifyOnExit = State(initialValue: defaults.object(forKey: "notifyOnExit") as? Bool ?? true)
            _notifyOnPass = State(initialValue: false)
            _isListMode = State(initialValue: false)
            _listItems = State(initialValue: [])
            _locationName = State(initialValue: String(localized: "Loading..."))
            _photoData = State(initialValue: nil)
            _selectedColorIndex = State(initialValue: 0)
            _currentCoordinate = State(initialValue: coordinate)

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

            // Trigger conditions
            _hasDeadline = State(initialValue: memo.deadline != nil)
            _deadline = State(initialValue: memo.deadline ?? Date())
            if let start = memo.timeWindowStart, let end = memo.timeWindowEnd {
                _hasTimeWindow = State(initialValue: true)
                _timeStart = State(initialValue: Self.makeTime(fromMinutes: start) ?? Date())
                _timeEnd   = State(initialValue: Self.makeTime(fromMinutes: end)   ?? Date())
            }
            if let days = memo.activeDays {
                _hasDayFilter = State(initialValue: true)
                _activeDays = State(initialValue: Set(days))
            }
            _isRouteTrigger = State(initialValue: memo.isRouteTrigger)
            _routeWaypoints = State(initialValue: memo.routeWaypoints)
            _exitDelayMinutes = State(initialValue: memo.exitDelayMinutes)
            _dwellMinutes = State(initialValue: memo.dwellMinutes)
            _isListMode = State(initialValue: memo.isListMode)
            _listItems = State(initialValue: memo.listItems)
            _selectedTags = State(initialValue: Set(memo.tags))
            _customTags = State(initialValue: memo.customTags)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // 基本: 場所・範囲・題・到着／退出。これだけで保存できる
                    MemoBasicsSection(
                        title: $title,
                        radius: $selectedRadius,
                        notifyOnEntry: $notifyOnEntry,
                        notifyOnExit: $notifyOnExit,
                        radiusCeiling: radiusCeiling,
                        coordinate: currentCoordinate,
                        locationBadgeText: locationBadgeText,
                        isRouteTrigger: isRouteTrigger,
                        routeWaypoints: routeWaypoints,
                        onTapLocation: {
                            if isRouteTrigger { showRouteEditor = true } else { showLocationPicker = true }
                        }
                    )

                    MemoDivider()

                    // 詳細: 閉じていても、設定済みの項目は要約で見える
                    AdvancedDisclosure(isExpanded: $showDetails, summary: advancedSummaryText) {
                        MemoAdvancedSection(
                            title: title,
                            locationName: locationName,
                            note: $note,
                            isListMode: $isListMode,
                            listItems: $listItems,
                            photoData: $photoData,
                            selectedColorIndex: $selectedColorIndex,
                            selectedTags: $selectedTags,
                            customTags: $customTags,
                            isRouteTrigger: $isRouteTrigger,
                            routeWaypoints: $routeWaypoints,
                            notifyOnEntry: $notifyOnEntry,
                            notifyOnExit: $notifyOnExit,
                            dwellMinutes: $dwellMinutes,
                            exitDelayMinutes: $exitDelayMinutes,
                            notifyOnPass: $notifyOnPass,
                            hasDeadline: $hasDeadline,
                            deadline: $deadline,
                            hasTimeWindow: $hasTimeWindow,
                            timeStart: $timeStart,
                            timeEnd: $timeEnd,
                            hasDayFilter: $hasDayFilter,
                            activeDays: $activeDays,
                            showRouteEditor: $showRouteEditor,
                            showProPaywall: $showProPaywall
                        )
                    }

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
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(String(localized: "Back"))

                        Text(mode.navigationTitle)
                            .font(.body.weight(.bold))
                            .foregroundColor(Brand.primaryText)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        HapticManager.notification(.success)
                        saveOrUpdate()
                    }) {
                        Text(mode.saveButtonLabel)
                            .font(.body.weight(.bold))
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
        }
        .sheet(isPresented: $showLocationPicker) {
            LocationPickerSheetV2(
                initialCoordinate: currentCoordinate,
                radius: selectedRadius,
                onLocationSelected: { newCoordinate, newLocationName in
                    currentCoordinate = newCoordinate
                    locationName = newLocationName
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
        .sheet(isPresented: $showProPaywall) {
            PaywallView()
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

    // MARK: - 基本・詳細のまとめ
    private var locationBadgeText: String {
        if isRouteTrigger {
            return routeWaypoints.isEmpty
                ? String(localized: "TAP TO ADD ROUTE")
                : String(format: String(localized: "%d WAYPOINTS"), routeWaypoints.count)
        }
        return locationName.uppercased()
    }

    private var advancedState: MemoAdvancedState {
        let cal = Calendar.current
        func minutes(_ d: Date) -> Int { cal.component(.hour, from: d) * 60 + cal.component(.minute, from: d) }
        return MemoAdvancedState(
            note: note,
            isListMode: isListMode,
            listItemCount: listItems.count,
            hasPhoto: photoData != nil,
            colorIndex: selectedColorIndex,
            tagCount: selectedTags.count + customTags.count,
            hasDeadline: hasDeadline,
            timeWindow: hasTimeWindow ? (minutes(timeStart), minutes(timeEnd)) : nil,
            activeDayCount: hasDayFilter ? activeDays.count : nil,
            isRouteTrigger: isRouteTrigger,
            waypointCount: routeWaypoints.count,
            notifyOnEntry: notifyOnEntry,
            notifyOnExit: notifyOnExit,
            dwellMinutes: dwellMinutes,
            exitDelayMinutes: exitDelayMinutes,
            notifyOnPass: notifyOnPass
        )
    }

    private var advancedSummaryText: String {
        MemoAdvancedSummary.text(for: MemoAdvancedSummary.items(for: advancedState))
    }

    // MARK: - Delete Section (edit mode only)
    private var deleteSection: some View {
        Button(action: { showDeleteAlert = true }) {
            Text("DELETE MEMO")
                .font(.body.weight(.bold))
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
            newMemo.dwellMinutes = (isRouteTrigger || !notifyOnEntry) ? nil : dwellMinutes
            newMemo.isListMode = isListMode
            newMemo.listItems = listItems
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
            memo.dwellMinutes = (isRouteTrigger || !notifyOnEntry) ? nil : dwellMinutes
            memo.isListMode = isListMode
            memo.listItems = listItems

            // Re-register geofencing
            if isRouteTrigger {
                locationManager.startMonitoringRoute(for: memo)
            } else {
                registerGeofencing(for: memo)
            }
        }

        // SwiftData autosave 任せだとバックグラウンド遷移直後に取り逃がすケースがあるため explicit に save。
        try? modelContext.save()
        geomemoApp.indexAllMemosInSpotlight()
        dismiss()
    }

    // MARK: - Delete Memo
    private func deleteMemo() {
        guard case .edit(let memo) = mode else { return }

        // Stop geofencing
        locationManager.stopMonitoring(memoID: memo.id.uuidString)

        // Delete from SwiftData
        let removedID = memo.id
        modelContext.delete(memo)
        try? modelContext.save()
        geomemoApp.handleMemoDeleted(id: removedID)

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

    /// 永続化された "分単位" (0..1439) を当日の Date に変換する。
    /// 不正値（負値や 1440 以上）でも nil を返すだけで crash しない。
    fileprivate static func makeTime(fromMinutes total: Int) -> Date? {
        let clamped = min(max(total, 0), 1439)
        return Calendar.current.date(
            bySettingHour: clamped / 60,
            minute: clamped % 60,
            second: 0,
            of: Date()
        )
    }
}

// MARK: - PhotoSectionView
/// MemoEditorView の body から切り出すことで、UIImage デコードが他の @State 変化時に走らなくなる。
struct PhotoSectionView: View {
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
                        .font(.body.weight(.bold))
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

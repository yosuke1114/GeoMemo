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
    @State private var locationName: String
    @State private var selectedPhoto: PhotosPickerItem?
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
        }
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
                Annotation("", coordinate: currentCoordinate) {
                    ZStack {
                        Circle()
                            .fill(Brand.primaryText)
                            .frame(width: 12, height: 12)
                        Circle()
                            .stroke(Brand.background, lineWidth: 2)
                            .frame(width: 12, height: 12)
                    }
                }

                // Radius circle
                MapCircle(center: currentCoordinate, radius: selectedRadius)
                    .foregroundStyle(Brand.blue.opacity(0.08))
                    .stroke(Brand.blue, lineWidth: 1.5)
            }
            .mapStyle({
                let style = GeoMapStyle(rawValue: mapStyleRaw) ?? .mono
                switch style {
                case .satellite: return .imagery
                default: return .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false)
                }
            }())
            .grayscale({
                let style = GeoMapStyle(rawValue: mapStyleRaw) ?? .mono
                return style == .mono && colorScheme != .dark ? 1.0 : 0
            }())
            .id(mapStyleRaw)
            .frame(height: 160)
            .onTapGesture {
                showLocationPicker = true
            }

            // Location Badge
            HStack(spacing: 6) {
                Image("ph-map-pin-fill")
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundColor(Brand.primaryText)

                Text(locationName.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Brand.primaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Brand.background)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Brand.primaryText, lineWidth: 1)
            )
            .padding(.leading, 16)
            .padding(.bottom, 16)
            .onTapGesture {
                showLocationPicker = true
            }
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
                    .foregroundColor(Brand.primaryText.opacity(0.3))
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
    private var photoSection: some View {
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
            .onChange(of: selectedPhoto) { oldValue, newValue in
                Task {
                    if let data = try? await newValue?.loadTransferable(type: Data.self) {
                        photoData = data
                    }
                }
            }

            // Photo Preview
            if let photoData, let uiImage = UIImage(data: photoData) {
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
                .foregroundColor(selectedRadius == value ? Brand.blue : Brand.primaryText.opacity(0.5))
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

    // MARK: - Notify Section
    private var notifySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NOTIFICATIONS")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Brand.primaryText.opacity(0.5))
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

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
        }
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
            let newMemo = GeoMemo(
                title: title.isEmpty ? String(localized: "Untitled") : title,
                note: note,
                latitude: currentCoordinate.latitude,
                longitude: currentCoordinate.longitude,
                radius: selectedRadius,
                locationName: locationName,
                imageData: photoData,
                notifyOnEntry: notifyOnEntry,
                notifyOnExit: notifyOnExit,
                deadline: hasDeadline ? deadline : nil,
                timeWindowStart: hasTimeWindow
                    ? cal.component(.hour, from: timeStart) * 60 + cal.component(.minute, from: timeStart)
                    : nil,
                timeWindowEnd: hasTimeWindow
                    ? cal.component(.hour, from: timeEnd) * 60 + cal.component(.minute, from: timeEnd)
                    : nil,
                activeDays: hasDayFilter ? Array(activeDays) : nil,
                colorIndex: selectedColorIndex
            )
            modelContext.insert(newMemo)
            registerGeofencing(for: newMemo)

        case .edit(let memo):
            let cal = Calendar.current

            // Stop existing geofencing
            locationManager.stopMonitoring(memoID: memo.id.uuidString)

            // Update SwiftData object
            memo.title = title.isEmpty ? String(localized: "Untitled") : title
            memo.note = note
            memo.latitude = currentCoordinate.latitude
            memo.longitude = currentCoordinate.longitude
            memo.radius = selectedRadius
            memo.locationName = locationName
            memo.imageData = photoData
            memo.notifyOnEntry = notifyOnEntry
            memo.notifyOnExit = notifyOnExit
            memo.deadline = hasDeadline ? deadline : nil
            memo.timeWindowStart = hasTimeWindow
                ? cal.component(.hour, from: timeStart) * 60 + cal.component(.minute, from: timeStart)
                : nil
            memo.timeWindowEnd = hasTimeWindow
                ? cal.component(.hour, from: timeEnd) * 60 + cal.component(.minute, from: timeEnd)
                : nil
            memo.activeDays = hasDayFilter ? Array(activeDays) : nil
            memo.colorIndex = selectedColorIndex

            // Re-register geofencing
            registerGeofencing(for: memo)
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
            let geocoder = CLGeocoder()
            let location = CLLocation(latitude: currentCoordinate.latitude, longitude: currentCoordinate.longitude)

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
                        locationName = String(localized: "Unknown Location")
                    }
                } else {
                    locationName = String(localized: "Unknown Location")
                }
            } catch {
                locationName = String(localized: "Unknown Location")
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

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
    @State private var newItemText: String = ""

    // Tags (Phase 2)
    @State private var selectedTags: Set<Int> = []
    @State private var customTags: [String] = []
    @State private var suggestedTags: [PresetTag] = []
    @State private var newCustomTag: String = ""
    @State private var showCustomTagInput = false
    @State private var tagSuggestTask: Task<Void, Never>? = nil

    @ObservedObject private var locationManager = LocationManager.shared
    @ObservedObject private var store = StoreKitManager.shared
    @State private var showProPaywall = false

    init(mode: MemoEditorMode, onDelete: (() -> Void)? = nil) {
        self.mode = mode
        self.onDelete = onDelete

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
                        advancedContent
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
            if case .edit = mode {
                refreshSuggestions()
            }
        }
        .onChange(of: title) { refreshSuggestionsDebounced() }
        .onChange(of: note) { refreshSuggestionsDebounced() }
        .onChange(of: locationName) { refreshSuggestionsDebounced() }
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

    /// 詳細に入る項目 (従来の並びのまま)
    @ViewBuilder
    private var advancedContent: some View {
        listModeToggleSection
        MemoDivider()
        if !isListMode {
            memoSection
            MemoDivider()
        }
        photoSection
        MemoDivider()
        colorSection
        MemoDivider()
        tagSection
        MemoDivider()
        notifySection
        MemoDivider()
        triggerConditionsSection
    }

    // MARK: - List Mode Toggle + Item Editor
    private var listModeToggleSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toggle row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LIST MODE")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(store.isPro ? Brand.primaryText.opacity(0.5) : Brand.secondaryText.opacity(0.5))
                    Text(String(localized: "Checklist instead of a note"))
                        .font(.caption)
                        .foregroundColor(store.isPro ? Brand.secondaryText : Brand.secondaryText.opacity(0.4))
                }
                Spacer()
                if store.isPro {
                    Toggle("", isOn: $isListMode)
                        .labelsHidden()
                        .tint(Brand.blue)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.body)
                        .foregroundStyle(Brand.secondaryText.opacity(0.5))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !store.isPro else { return }
                HapticManager.impact(.light)
                showProPaywall = true
            }

            if isListMode {
                Divider()
                    .background(Brand.primaryText.opacity(0.1))
                    .padding(.horizontal, 20)

                // Existing items
                ForEach($listItems) { $item in
                    HStack(spacing: 12) {
                        Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(item.isChecked ? Brand.blue : Brand.primaryText.opacity(0.3))
                            .onTapGesture {
                                HapticManager.selection()
                                item.isChecked.toggle()
                            }
                        TextField(String(localized: "Item"), text: $item.text)
                            .font(.body)
                            .foregroundColor(Brand.primaryText)
                        Spacer()
                        Button(action: {
                            HapticManager.selection()
                            listItems.removeAll { $0.id == item.id }
                        }) {
                            Image(systemName: "xmark")
                                .font(.footnote.weight(.medium))
                                .foregroundColor(Brand.primaryText.opacity(0.3))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }

                // Add new item row
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundColor(Brand.blue.opacity(0.6))
                    TextField(String(localized: "Add item…"), text: $newItemText)
                        .font(.body)
                        .foregroundColor(Brand.primaryText)
                        .submitLabel(.done)
                        .onSubmit { addListItem() }
                    if !newItemText.isEmpty {
                        Button(action: addListItem) {
                            Text(String(localized: "追加"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Brand.blue)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isListMode)
        .animation(.easeInOut(duration: 0.15), value: listItems.count)
    }

    private func addListItem() {
        let trimmed = newItemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        HapticManager.selection()
        listItems.append(ListItem(text: trimmed))
        newItemText = ""
    }

    // MARK: - Memo Section
    private var memoSection: some View {
        ZStack(alignment: .topLeading) {
            if note.isEmpty {
                Text("Memo")
                    .font(.body)
                    .foregroundColor(Brand.tertiaryText)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
            }

            TextEditor(text: $note)
                .font(.body)
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

    // MARK: - Color Section
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("COLOR")
                .font(.footnote.weight(.semibold))
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
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Brand.primaryText.opacity(0.5))
                Spacer()
                Button(action: {
                    HapticManager.selection()
                    refreshSuggestions()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.footnote)
                        Text(String(localized: "AI提案"))
                            .font(.caption.weight(.medium))
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
                        .font(.subheadline)
                        .foregroundStyle(Brand.primaryText)
                        .submitLabel(.done)
                        .onSubmit { addCustomTag() }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Brand.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button(action: addCustomTag) {
                        Text(String(localized: "追加"))
                            .font(.subheadline.weight(.semibold))
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
                            .font(.subheadline)
                        Text(showCustomTagInput
                             ? String(localized: "キャンセル")
                             : String(localized: "カスタムタグを追加"))
                            .font(.footnote.weight(.medium))
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
                .font(.footnote.weight(.semibold))
                .foregroundColor(Brand.primaryText.opacity(0.5))
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // ROUTE TRIGGER
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ROUTE TRIGGER")
                        .font(.body.weight(.semibold))
                        .foregroundColor(store.isPro ? Brand.primaryText : Brand.primaryText.opacity(0.4))
                    Text(String(localized: "Notify when passing waypoints"))
                        .font(.caption)
                        .foregroundColor(store.isPro ? Brand.secondaryText : Brand.secondaryText.opacity(0.4))
                }
                Spacer()
                if store.isPro {
                    Toggle("", isOn: $isRouteTrigger)
                        .labelsHidden()
                        .tint(Brand.blue)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.body)
                        .foregroundStyle(Brand.secondaryText.opacity(0.5))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !store.isPro else { return }
                HapticManager.impact(.light)
                showProPaywall = true
            }

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
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Brand.blue)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(Brand.secondaryText)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                if notifyOnEntry {
                    Divider()
                        .background(Brand.primaryText.opacity(0.1))
                        .padding(.horizontal, 20)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DWELL TIME")
                                .font(.body.weight(.semibold))
                                .foregroundColor(Brand.primaryText)
                            Text(String(localized: "Notify after staying in the area"))
                                .font(.caption)
                                .foregroundColor(Brand.secondaryText)
                        }
                        Spacer()
                        Picker("", selection: $dwellMinutes) {
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

                if notifyOnExit {
                    Divider()
                        .background(Brand.primaryText.opacity(0.1))
                        .padding(.horizontal, 20)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("EXIT DELAY")
                                .font(.body.weight(.semibold))
                                .foregroundColor(Brand.primaryText)
                            Text(String(localized: "Notify after leaving the area"))
                                .font(.caption)
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
                            .font(.body.weight(.semibold))
                            .foregroundColor(Brand.primaryText)
                        Text(String(localized: "Show in Dynamic Island when nearby"))
                            .font(.caption)
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
                .font(.footnote.weight(.semibold))
                .foregroundColor(Brand.primaryText.opacity(0.5))
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // 期限 (EXPIRY)
            HStack {
                Text("EXPIRY")
                    .font(.body.weight(.semibold))
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
                    .font(.body.weight(.semibold))
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
                    .font(.body.weight(.semibold))
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
                        .font(.footnote.weight(.medium))
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

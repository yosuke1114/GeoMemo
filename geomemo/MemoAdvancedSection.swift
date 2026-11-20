import SwiftUI
import PhotosUI

/// メモ編集の「詳細」(メモ・リスト・写真・色・タグ・通知の詳細・発動条件)。
/// 範囲 (radius) は受け取らない。スライダー操作のたびにここが再評価されないようにするため。
struct MemoAdvancedSection: View {
    // 値 (タグの提案に使う)
    let title: String
    let locationName: String

    @Binding var note: String
    @Binding var isListMode: Bool
    @Binding var listItems: [ListItem]
    @Binding var photoData: Data?
    @Binding var selectedColorIndex: Int
    @Binding var selectedTags: Set<Int>
    @Binding var customTags: [String]
    @Binding var isRouteTrigger: Bool
    @Binding var routeWaypoints: [RouteWaypoint]
    @Binding var notifyOnEntry: Bool
    @Binding var notifyOnExit: Bool
    @Binding var dwellMinutes: Int?
    @Binding var exitDelayMinutes: Int?
    @Binding var notifyOnPass: Bool
    @Binding var hasDeadline: Bool
    @Binding var deadline: Date
    @Binding var hasTimeWindow: Bool
    @Binding var timeStart: Date
    @Binding var timeEnd: Date
    @Binding var hasDayFilter: Bool
    @Binding var activeDays: Set<Int>
    @Binding var showRouteEditor: Bool
    @Binding var showProPaywall: Bool

    @ObservedObject private var store = StoreKitManager.shared
    @State private var newItemText: String = ""
    @State private var newCustomTag: String = ""
    @State private var showCustomTagInput = false
    @State private var suggestedTags: [PresetTag] = []
    @State private var tagSuggestTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
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
        .onAppear { refreshSuggestions() }
        .onChange(of: title) { refreshSuggestionsDebounced() }
        .onChange(of: note) { refreshSuggestionsDebounced() }
        .onChange(of: locationName) { refreshSuggestionsDebounced() }
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
}

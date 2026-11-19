import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import CloudKit

// リストタブ。ContentView.swift から分離。

// MARK: - List Tab View
struct ListTabView: View {
    let memos: [GeoMemo]
    @Environment(\.modelContext) private var modelContext

    @ObservedObject private var locationManager = LocationManager.shared
    @State private var selectedTab: FilterTab = .all
    @Namespace private var tabNamespace
    @Binding var intentShowFavorites: Bool
    @Binding var showList: Bool
    @Binding var showSettings: Bool
    @Query(sort: \SharedMemo.createdAt, order: .reverse) private var allSharedMemos: [SharedMemo]

    /// 空状態の大きな装飾アイコンを Dynamic Type に追従させる。
    @ScaledMetric(relativeTo: .largeTitle) private var emptyTabIconSize: CGFloat = 36

    private var receivedActiveMemos: [SharedMemo] {
        allSharedMemos.filter { !$0.isMyRequest && ($0.status == .active || $0.status == .fired) }
    }

    @State private var showDoneSection: Bool = false
    @State private var selectedReceived: SharedMemo?
    @State private var pendingDeleteReceived: SharedMemo?
    @State private var showColorFilter: Bool = false
    @State private var selectedColorIndex: Int? = nil
    @State private var isListSearching = false
    @State private var listSearchText = ""

    // MARK: - Filter Tab

    enum FilterTab: Hashable {
        case favorites
        case all
        case tag(PresetTag)

        var accessibilityLabel: String {
            switch self {
            case .favorites: return String(localized: "Favorites")
            case .all:        return String(localized: "ALL")
            case .tag(let t): return t.localizedName
            }
        }
    }

    // MARK: - Computed Properties

    private var filterTabs: [FilterTab] {
        var tabs: [FilterTab] = [.favorites, .all]
        let usedIds = Set(memos.flatMap { $0.tags })
        tabs += PresetTag.allCases
            .filter { usedIds.contains($0.rawValue) }
            .map { .tag($0) }
        return tabs
    }

    private func memos(for tab: FilterTab) -> [GeoMemo] {
        var results: [GeoMemo]
        switch tab {
        case .favorites: results = memos.filter { $0.isFavorite && !$0.isDone }
        case .all:        results = memos.filter { !$0.isDone }
        case .tag(let t): results = memos.filter { $0.tags.contains(t.rawValue) && !$0.isDone }
        }
        if let colorIndex = selectedColorIndex {
            results = results.filter { $0.colorIndex == colorIndex }
        }
        if !listSearchText.isEmpty {
            let q = listSearchText.lowercased()
            results = results.filter {
                $0.title.lowercased().contains(q) ||
                $0.note.lowercased().contains(q) ||
                $0.locationName.lowercased().contains(q)
            }
        }
        return results
    }

    private var doneMemos: [GeoMemo] {
        memos.filter { $0.isDone }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // カスタムナビゲーションバー（プロダクト名なし）
                listNavigationBar

                // メモ検索バー
                if isListSearching {
                    HStack(spacing: 8) {
                        Image("ph-magnifying-glass-bold")
                            .resizable()
                            .frame(width: 16, height: 16)
                            .foregroundColor(Brand.tertiaryText)
                        TextField(String(localized: "Search memos..."), text: $listSearchText)
                            .font(.body)
                            .foregroundColor(Brand.primaryText)
                        if !listSearchText.isEmpty {
                            Button(action: { listSearchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(Brand.secondaryText)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Brand.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                switch ListContentState.resolve(ownMemoCount: memos.count,
                                                receivedCount: receivedActiveMemos.count) {
                case .empty:
                    Spacer()
                    VStack(spacing: 16) {
                        Image("ph-map-trifold-thin")
                            .resizable()
                            .frame(width: 48, height: 48)
                            .foregroundColor(Brand.primaryText.opacity(0.45))
                        Text("No memos yet")
                            .font(.body.weight(.medium))
                            .foregroundColor(Brand.primaryText.opacity(0.5))
                        Text("Tap the map to add a memo")
                            .font(.subheadline)
                            .foregroundColor(Brand.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    Spacer()
                case .receivedOnly:
                    // 自分のメモが 0 件でも、受信した依頼は見えるようにする。
                    memoList(for: .all)
                case .memos:
                    tabBar
                    pageContent
                }
            }
            .background(Brand.background)
            .navigationBarHidden(true)
            .sheet(item: $selectedReceived) { shared in
                ReceivedSharedMemoDetailView(
                    shared: shared,
                    onDelete: { deleteReceivedSharedMemo(shared, in: modelContext) },
                    onComplete: { completeReceivedSharedMemo(shared, in: modelContext) }
                )
            }
            .animation(.easeInOut(duration: 0.2), value: isListSearching)
            .confirmationDialog(
                String(localized: "この依頼を削除しますか？"),
                isPresented: Binding(
                    get: { pendingDeleteReceived != nil },
                    set: { if !$0 { pendingDeleteReceived = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeleteReceived
            ) { shared in
                Button(String(localized: "削除"), role: .destructive) {
                    deleteReceivedSharedMemo(shared, in: modelContext)
                }
                Button(String(localized: "キャンセル"), role: .cancel) {}
            } message: { _ in
                Text(String(localized: "この端末から削除し、共有から抜けます。依頼した人の側には残ります。"))
            }
        }
        .onChange(of: intentShowFavorites) { _, newValue in
            if newValue {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    selectedTab = .favorites
                }
                intentShowFavorites = false
            }
        }
    }

    // MARK: - List Navigation Bar
    private var listNavigationBar: some View {
        HStack(spacing: 12) {
            // マップへ戻るボタン
            Button(action: {
                HapticManager.impact(.light)
                withAnimation(.easeInOut(duration: 0.3)) { showList = false }
            }) {
                HStack(spacing: 4) {
                    Image("ph-arrow-left-bold")
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text("MAP")
                        .font(.body.weight(.bold))
                }
                .foregroundColor(Brand.primaryText)
            }

            Spacer()

            // メモ検索ボタン
            Button(action: {
                withAnimation(.easeInOut(duration: 0.25)) { isListSearching.toggle() }
                if !isListSearching { listSearchText = "" }
            }) {
                Image("ph-magnifying-glass-bold")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundColor(isListSearching ? Brand.blue : Brand.primaryText)
                    .frame(width: 32, height: 32)
            }

            // 設定ボタン
            Button(action: { showSettings = true }) {
                Image("ph-gear-six-bold")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundColor(Brand.primaryText)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Brand.background)
        .overlay(Rectangle().fill(Brand.border).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Tab Bar

    private var usedColors: [MemoColor] {
        let indices = Set(memos.filter { !$0.isDone }.map { $0.colorIndex })
        return MemoColor.allCases.filter { indices.contains($0.rawValue) }
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    ScrollViewReader { proxy in
                        HStack(spacing: 0) {
                            ForEach(filterTabs, id: \.self) { tab in
                                tabButton(tab)
                            }
                        }
                        .padding(.horizontal, 8)
                        .onChange(of: selectedTab) { _, newTab in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(newTab, anchor: .center)
                            }
                        }
                    }
                }

                // Color Filter Toggle Button
                if usedColors.count > 1 {
                    Button {
                        HapticManager.selection()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showColorFilter.toggle()
                            if !showColorFilter { selectedColorIndex = nil }
                        }
                    } label: {
                        ZStack {
                            if let ci = selectedColorIndex,
                               let color = MemoColor(rawValue: ci)?.color {
                                Circle()
                                    .fill(color)
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "circle.grid.3x3")
                                    .font(.subheadline)
                                    .foregroundColor(showColorFilter ? Brand.blue : Brand.secondaryText)
                            }
                        }
                        .frame(width: 44, height: 44)
                    }
                    .padding(.trailing, 4)
                }
            }

            // Accordion Color Filter
            if showColorFilter && usedColors.count > 1 {
                HStack(spacing: 12) {
                    // "All" (no color filter)
                    Button {
                        HapticManager.selection()
                        selectedColorIndex = nil
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Brand.secondaryBackground)
                                .frame(width: 28, height: 28)
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(selectedColorIndex == nil ? Brand.primaryText : Brand.secondaryText)
                        }
                        .overlay(
                            Circle()
                                .stroke(selectedColorIndex == nil ? Brand.primaryText : Color.clear, lineWidth: 2)
                        )
                    }

                    ForEach(usedColors, id: \.rawValue) { memoColor in
                        Button {
                            HapticManager.selection()
                            if selectedColorIndex == memoColor.rawValue {
                                selectedColorIndex = nil
                            } else {
                                selectedColorIndex = memoColor.rawValue
                            }
                        } label: {
                            Circle()
                                .fill(memoColor.color)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle()
                                        .stroke(Brand.primaryText, lineWidth: selectedColorIndex == memoColor.rawValue ? 2 : 0)
                                )
                                .overlay(
                                    Circle()
                                        .stroke(Brand.background, lineWidth: selectedColorIndex == memoColor.rawValue ? 3 : 0)
                                        .padding(2)
                                )
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Brand.secondaryBackground)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Brand.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Brand.border)
                .frame(height: 1)
        }
        .animation(.easeInOut(duration: 0.2), value: showColorFilter)
    }

    private func tabButton(_ tab: FilterTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            HapticManager.selection()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                prevTab = selectedTab
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 0) {
                tabLabel(tab, isSelected: isSelected)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .animation(.easeInOut(duration: 0.15), value: isSelected)

                // Sliding underline
                ZStack {
                    if isSelected {
                        Rectangle()
                            .fill(tab == .favorites ? Color(hex: "E5484D") : Brand.blue)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "tabLine", in: tabNamespace)
                    } else {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: 2)
                    }
                }
            }
        }
        .id(tab)
        .accessibilityLabel(tab.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func tabLabel(_ tab: FilterTab, isSelected: Bool) -> some View {
        switch tab {
        case .favorites:
            Image(systemName: isSelected ? "heart.fill" : "heart")
                .font(.subheadline)
                .foregroundColor(isSelected ? Color(hex: "E5484D") : Brand.secondaryText)
        case .all:
            Text(String(localized: "ALL"))
                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? Brand.primaryText : Brand.secondaryText)
        case .tag(let tag):
            Text(tag.localizedName)
                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? Brand.primaryText : Brand.secondaryText)
        }
    }

    // MARK: - Page Content

    @State private var prevTab: FilterTab = .all

    private var pageContent: some View {
        let isForward = filterTabs.firstIndex(of: selectedTab).map { new in
            filterTabs.firstIndex(of: prevTab).map { new >= $0 } ?? true
        } ?? true
        return memoList(for: selectedTab)
            .id(selectedTab)
            .transition(.asymmetric(
                insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
                removal:   .move(edge: isForward ? .leading  : .trailing).combined(with: .opacity)
            ))
    }

    @ViewBuilder
    private func memoList(for tab: FilterTab) -> some View {
        let tabMemos = memos(for: tab)
        if tabMemos.isEmpty && doneMemos.isEmpty && !(tab == .all && !receivedActiveMemos.isEmpty) {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: tab == .favorites ? "heart" : "tray")
                    .font(.system(size: emptyTabIconSize))
                    .foregroundColor(Brand.primaryText.opacity(0.2))
                Text(tab == .favorites
                     ? String(localized: "No favorites yet")
                     : String(localized: "No matching memos"))
                    .font(.body.weight(.medium))
                    .foregroundColor(Brand.primaryText.opacity(0.4))
                Spacer()
            }
        } else {
            List {
                // 受信した依頼セクション（ALL タブのみ）
                if tab == .all && !receivedActiveMemos.isEmpty {
                    Section {
                        ForEach(receivedActiveMemos) { shared in
                            receivedMemoRow(shared)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedReceived = shared }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        HapticManager.notification(.warning)
                                        pendingDeleteReceived = shared
                                    } label: {
                                        Label(String(localized: "削除"), systemImage: "trash")
                                    }
                                }
                                .accessibilityAddTraits(.isButton)
                                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                                .listRowSeparator(.visible, edges: .bottom)
                                .listRowSeparatorTint(Brand.primaryText.opacity(0.1))
                                .listRowBackground(Brand.surface.opacity(0.6))
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.2.fill")
                                .font(.caption2.weight(.semibold))
                            Text(String(localized: "受信した依頼") + " (\(receivedActiveMemos.count))")
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                        }
                        .foregroundColor(Brand.blue)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                    }
                }

                // 通常メモ
                ForEach(tabMemos) { memo in
                    NavigationLink(destination: MemoDetailView(memo: memo)) {
                        MemoListRow(memo: memo, userLocation: locationManager.location?.coordinate)
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                    .listRowSeparator(.visible, edges: .bottom)
                    .listRowSeparatorTint(Brand.primaryText.opacity(0.1))
                    .listRowBackground(Brand.background)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))
                    .swipeActions(edge: .leading) {
                        Button {
                            HapticManager.notification(.success)
                            memo.isDone = true
                            if memo.isRouteTrigger {
                                locationManager.stopMonitoringRoute(memoID: memo.id.uuidString)
                            } else {
                                locationManager.stopMonitoring(memoID: memo.id.uuidString)
                            }
                        } label: {
                            Label("Complete", systemImage: "checkmark")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            HapticManager.notification(.warning)
                            delete(memo)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

                // 完了済みセクション
                if !doneMemos.isEmpty {
                    Section {
                        if showDoneSection {
                            ForEach(doneMemos) { memo in
                                NavigationLink(destination: MemoDetailView(memo: memo)) {
                                    MemoListRow(memo: memo, userLocation: locationManager.location?.coordinate)
                                }
                                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                                .listRowSeparator(.visible, edges: .bottom)
                                .listRowSeparatorTint(Brand.primaryText.opacity(0.1))
                                .listRowBackground(Brand.background)
                                .swipeActions(edge: .leading) {
                                    Button {
                                        HapticManager.impact(.light)
                                        memo.isDone = false
                                        if memo.isRouteTrigger {
                                            locationManager.startMonitoringRoute(for: memo)
                                        } else if let region = memo.region {
                                            locationManager.startMonitoring(region: region)
                                        }
                                    } label: {
                                        Label("Restore", systemImage: "arrow.uturn.left")
                                    }
                                    .tint(Brand.blue)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        HapticManager.notification(.warning)
                                        delete(memo)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } header: {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showDoneSection.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showDoneSection ? "chevron.down" : "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                Text("Complete (\(doneMemos.count))")
                                    .font(.caption.weight(.semibold))
                                    .textCase(nil)
                            }
                            .foregroundColor(Brand.secondaryText)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Brand.background)
        }
    }

    // MARK: - Received Shared Memo Row

    @ViewBuilder
    private func receivedMemoRow(_ shared: SharedMemo) -> some View {
        HStack(spacing: 12) {
            // ステータスアイコン
            Group {
                if shared.status == .fired {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "clock")
                        .foregroundStyle(Brand.blue)
                }
            }
            .font(.body)
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(shared.memoTitle.isEmpty ? String(localized: "（タイトルなし）") : shared.memoTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                    .lineLimit(1)
                Text(String(localized: "依頼: ") + shared.requesterName)
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
            }

            Spacer()

            // 手動完了ボタン（発火後のみ表示）
            if shared.status == .fired {
                Button {
                    HapticManager.notification(.success)
                    completeReceivedSharedMemo(shared, in: modelContext)
                } label: {
                    Text(String(localized: "完了"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Brand.blue)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func delete(_ memo: GeoMemo) {
        locationManager.stopMonitoring(memoID: memo.id.uuidString)
        let removedID = memo.id
        modelContext.delete(memo)
        geomemoApp.handleMemoDeleted(id: removedID)
    }
}

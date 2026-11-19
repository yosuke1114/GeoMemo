import SwiftUI
import SwiftData
import CloudKit

// MARK: - 見守りダッシュボード（依頼者が確認する画面）

struct WatchDashboardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SharedMemo.createdAt, order: .reverse) private var allSharedMemos: [SharedMemo]
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]

    private var myProfile: UserProfile? { profiles.first }

    /// 自分が依頼した（送信側）メモ
    private var sentMemos: [SharedMemo] {
        allSharedMemos.filter { $0.isMyRequest && $0.status != .cancelled }
    }

    /// 受信者ごとにグループ化
    private var groupedByRecipient: [(name: String, memos: [SharedMemo])] {
        let grouped = Dictionary(grouping: sentMemos, by: \.recipientName)
        return grouped.map { (name: $0.key, memos: $0.value) }
            .sorted { $0.name < $1.name }
    }

    @State private var isSyncing = false
    @State private var pendingCount = 0
    @State private var editing: SharedMemo?
    @State private var resendLink: ShareLinkItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if pendingCount > 0 {
                    pendingBanner
                }
                Group {
                    if sentMemos.isEmpty {
                        emptyState
                    } else {
                        dashboardList
                    }
                }
            }
            .background(Brand.background)
            .sheet(item: $editing) { shared in
                EditSharedMemoSheet(shared: shared)
            }
            .sheet(item: $resendLink) { item in
                ActivityShareSheet(items: [item.url])
                    .presentationDetents([.medium, .large])
            }
            .navigationTitle(String(localized: "見守り"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "完了")) { dismiss() }
                        .foregroundStyle(Brand.primaryText)
                }
                ToolbarItem(placement: .primaryAction) {
                    if isSyncing {
                        ProgressView()
                            .accessibilityLabel(String(localized: "更新中"))
                    } else {
                        Button {
                            Task { await syncStatus() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(Brand.blue)
                        }
                        .accessibilityLabel(String(localized: "最新の状態に更新"))
                    }
                }
            }
        }
        .task {
            await syncStatus()
            pendingCount = PendingEventQueue.shared.all.count
        }
    }

    // MARK: - 再送待ちバナー

    private var pendingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
                .font(.footnote.weight(.semibold))
                .accessibilityHidden(true)
            Text(String(localized: "未送信の更新が \(pendingCount) 件あります。通信が戻り次第再送します。"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(Brand.primaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }

    // MARK: - 空状態

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash")
                .font(.system(size: emptyStateIconSize))
                .foregroundStyle(Brand.secondaryText.opacity(0.4))
                .accessibilityHidden(true)
            Text(String(localized: "依頼中のメモはありません"))
                .font(.body.weight(.semibold))
                .foregroundStyle(Brand.primaryText)
            Text(String(localized: "メモ詳細から「依頼する」ボタンで\nフレンドに依頼できます。"))
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Dynamic Type 設定に応じて空状態の大きな装飾アイコンを伸縮させる。
    @ScaledMetric(relativeTo: .largeTitle) private var emptyStateIconSize: CGFloat = 48

    // MARK: - ダッシュボードリスト

    private var dashboardList: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(groupedByRecipient, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        // 人名ヘッダー
                        HStack(spacing: 8) {
                            Image(systemName: "person.circle.fill")
                                .font(.footnote)
                                .imageScale(.large)
                                .foregroundStyle(Brand.blue)
                                .accessibilityHidden(true)
                            Text(group.name)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Brand.secondaryText)
                                .tracking(0.5)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)

                        VStack(spacing: 0) {
                            ForEach(group.memos) { shared in
                                sharedMemoRow(shared)
                                if shared.id != group.memos.last?.id {
                                    Rectangle()
                                        .fill(Brand.separator)
                                        .frame(height: 1)
                                        .padding(.leading, 16)
                                }
                            }
                        }
                        .background(Brand.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .refreshable { await syncStatus() }
    }

    // MARK: - 行

    private func sharedMemoRow(_ shared: SharedMemo) -> some View {
        HStack(spacing: 12) {
            // ステータスアイコン
            statusIcon(for: shared.status)
                .frame(minWidth: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(shared.memoTitle.isEmpty ? String(localized: "（タイトルなし）") : shared.memoTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusTitleColor(for: shared.status))
                    .lineLimit(2)

                statusSubtitle(for: shared)
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel(for: shared))
        // ScrollView/VStack 内では .swipeActions が動かないため長押しメニューで代替。
        .contextMenu {
            if shared.isActive {
                Button {
                    editing = shared
                } label: {
                    Label(String(localized: "内容・期限を編集"), systemImage: "pencil")
                }
            }
            if shared.status == .active {
                Button {
                    Task { await resend(shared) }
                } label: {
                    Label(String(localized: "リンクを送り直す"), systemImage: "link")
                }
                Button(role: .destructive) {
                    Task { await cancelSharedMemo(shared) }
                } label: {
                    Label(String(localized: "キャンセル"), systemImage: "xmark")
                }
            }
        }
    }

    private func rowAccessibilityLabel(for shared: SharedMemo) -> String {
        let title = shared.memoTitle.isEmpty
            ? String(localized: "タイトルなし")
            : shared.memoTitle
        let statusText: String = {
            switch shared.status {
            case .active:    return String(localized: "監視中")
            case .fired:     return String(localized: "到着済み")
            case .completed: return String(localized: "完了")
            case .cancelled: return String(localized: "キャンセル済み")
            }
        }()
        return "\(title)、\(statusText)"
    }

    @ViewBuilder
    private func statusIcon(for status: ShareStatus) -> some View {
        switch status {
        case .active:
            Image(systemName: "clock")
                .foregroundStyle(Brand.blue)
        case .fired:
            Image(systemName: "location.fill")
                .foregroundStyle(.orange)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Brand.secondaryText)
        }
    }

    private func statusTitleColor(for status: ShareStatus) -> Color {
        switch status {
        case .completed: return Brand.primaryText.opacity(0.5)
        case .cancelled: return Brand.secondaryText
        default: return Brand.primaryText
        }
    }

    @ViewBuilder
    private func statusSubtitle(for shared: SharedMemo) -> some View {
        switch shared.status {
        case .active:
            if let deadline = shared.memoDeadline {
                Text("〜\(deadline, format: .dateTime.hour().minute())")
            } else {
                Text(String(localized: "監視中"))
            }
        case .fired:
            if let firedAt = shared.firedAt {
                Text("\(String(localized: "到着")) \(firedAt, format: .dateTime.hour().minute())")
            } else {
                Text(String(localized: "到着済み・完了待ち"))
            }
        case .completed:
            if let completedAt = shared.completedAt {
                Text("\(String(localized: "完了")) \(completedAt, format: .dateTime.hour().minute())")
            } else {
                Text(String(localized: "完了"))
            }
        case .cancelled:
            Text(String(localized: "キャンセル済み"))
        }
    }

    // MARK: - Sync

    private func syncStatus() async {
        guard !isSyncing, myProfile != nil else { return }
        isSyncing = true
        defer {
            isSyncing = false
            pendingCount = PendingEventQueue.shared.all.count
        }
        // pull-to-refresh / 手動更新も兼ねるので、未処理の再送イベントもここで掃く
        await PendingEventQueue.shared.drain()
        do {
            let sentData = try await CKShareService.shared.fetchSentSharedMemos()
            var didChange = false
            for data in sentData {
                let recordName = data.ckRecordID.recordName
                if let local = allSharedMemos.first(where: { $0.ckRecordName == recordName }) {
                    if local.apply(data) { didChange = true }
                    // 相手が受け取った依頼なら、依頼者側にも相手をフレンドとして登録（双方向）
                    if FriendConnection.registerIfNeeded(recordID: local.recipientRecordID,
                                                          displayName: local.recipientName, in: modelContext) {
                        didChange = true
                    }
                }
            }
            if didChange { try? modelContext.save() }
        } catch {
            ToastCenter.shared.show(.warning(
                String(localized: "最新の状態を取得できませんでした。通信状況を確認してください。")
            ))
        }
    }

    // MARK: - Resend link

    private func resend(_ shared: SharedMemo) async {
        do {
            if let url = try await CKShareService.shared.shareURL(for: shared.cloudKitRecordID) {
                resendLink = ShareLinkItem(url: url)
                return
            }
        } catch {}
        ToastCenter.shared.show(.warning(
            String(localized: "共有リンクを取得できませんでした。通信状況を確認してください。")
        ))
    }

    // MARK: - Cancel

    private func cancelSharedMemo(_ shared: SharedMemo) async {
        do {
            try await CKShareService.shared.cancelSharedMemo(recordID: shared.cloudKitRecordID)
            shared.status = .cancelled
            try? modelContext.save()
        } catch {
            // オフライン等で書き込み失敗 → 再送キューに積み、次回 drain で送り直す。
            // 楽観的にローカル状態も cancelled にしてしまうとサーバとズレるので残す。
            PendingEventQueue.shared.enqueue(
                .cancelled(ckRecordName: shared.ckRecordName, zoneOwnerName: shared.zoneOwnerName)
            )
            ToastCenter.shared.show(.warning(
                String(localized: "キャンセルを送信できませんでした。通信が戻ったとき自動で再送します。")
            ))
            pendingCount = PendingEventQueue.shared.all.count
        }
    }
}

// MARK: - 送信後の編集（依頼者）

/// 送った依頼のタイトル・本文・期限を編集する。保存すると受信側の次回同期で反映される。
private struct EditSharedMemoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let shared: SharedMemo

    @State private var title = ""
    @State private var note = ""
    @State private var hasDeadline = false
    @State private var deadline = Date()
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "タイトル")) {
                    TextField(String(localized: "タイトル"), text: $title)
                }
                Section(String(localized: "メモ")) {
                    TextField(String(localized: "メモ"), text: $note, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    Toggle(String(localized: "期限を設定"), isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker(String(localized: "期限"), selection: $deadline, in: Date()...)
                    }
                } footer: {
                    Text(String(localized: "保存すると、相手のアプリにも反映されます。場所は変更できません。"))
                }
            }
            .navigationTitle(String(localized: "依頼を編集"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "キャンセル")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(String(localized: "保存")) { Task { await save() } }
                    }
                }
            }
            .onAppear {
                title = shared.memoTitle
                note = SharedMemoNoteStore.note(for: shared.ckRecordName)
                hasDeadline = shared.memoDeadline != nil
                deadline = shared.memoDeadline ?? Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let newDeadline = hasDeadline ? deadline : nil
        do {
            try await CKShareService.shared.updateSharedMemoContent(
                recordID: shared.cloudKitRecordID, title: title, note: note, deadline: newDeadline)
            shared.memoTitle = title
            shared.memoDeadline = newDeadline
            SharedMemoNoteStore.setNote(note, for: shared.ckRecordName)
            try? modelContext.save()
            dismiss()
        } catch {
            ToastCenter.shared.show(.warning(
                String(localized: "依頼を更新できませんでした。通信状況を確認してください。")
            ))
        }
    }
}

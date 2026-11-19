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
    /// 取り消しの確認待ちの依頼
    @State private var pendingCancel: SharedMemo?
    /// 送れたか分からず「未送信」として残している依頼（`UnsentShareStore`）
    @State private var unsentRecordNames: Set<String> = []

    private func refreshUnsent() {
        unsentRecordNames = UnsentShareStore.shared.keptRecordNames
    }

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
            .confirmationDialog(
                String(localized: "この依頼を取り消しますか？"),
                isPresented: Binding(
                    get: { pendingCancel != nil },
                    set: { if !$0 { pendingCancel = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingCancel
            ) { shared in
                Button(String(localized: "依頼を取り消す"), role: .destructive) {
                    Task { await cancelSharedMemo(shared) }
                }
                Button(String(localized: "戻る"), role: .cancel) {}
            } message: { _ in
                Text(String(localized: "取り消した依頼は、見守りの一覧から消えます。"))
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
            refreshUnsent()
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

                if isUnsent(shared) {
                    Text(String(localized: "未送信・送れたか確認できませんでした"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else {
                    statusSubtitle(for: shared)
                        .font(.caption)
                        .foregroundStyle(Brand.secondaryText)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel(for: shared))
        // ScrollView/VStack 内では .swipeActions が動かないため長押しメニューで代替。
        .contextMenu {
            // 編集・送り直し・キャンセルは監視中の依頼だけ。到着・完了後にレコードを書き換えると、
            // 依頼者への「到着」「完了」通知が再び届いてしまう。
            if shared.status == .active {
                Button {
                    editing = shared
                } label: {
                    Label(String(localized: "内容・期限を編集"), systemImage: "pencil")
                }
                Button {
                    Task { await resend(shared) }
                } label: {
                    Label(String(localized: "リンクを送り直す"), systemImage: "link")
                }
                if isUnsent(shared) {
                    // 送れたか分からない依頼。相手に届いていなければサーバから消す
                    Button(role: .destructive) {
                        Task { await deleteUnsent(shared) }
                    } label: {
                        Label(String(localized: "削除"), systemImage: "trash")
                    }
                } else {
                    Button(role: .destructive) {
                        pendingCancel = shared
                    } label: {
                        Label(String(localized: "依頼を取り消す"), systemImage: "xmark")
                    }
                }
            }
        }
    }

    private func isUnsent(_ shared: SharedMemo) -> Bool {
        shared.status == .active && unsentRecordNames.contains(shared.ckRecordName)
    }

    private func rowAccessibilityLabel(for shared: SharedMemo) -> String {
        let title = shared.memoTitle.isEmpty
            ? String(localized: "タイトルなし")
            : shared.memoTitle
        let statusText: String = {
            switch shared.status {
            case .active:    return String(localized: "到着待ち")
            case .fired:     return String(localized: "到着済み")
            case .completed: return String(localized: "完了")
            case .cancelled: return String(localized: "キャンセル済み")
            }
        }()
        if isUnsent(shared) {
            return "\(title)、\(String(localized: "未送信"))"
        }
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
                Text("〜\(dayAndTimeText(deadline))")
            } else {
                Text(String(localized: "到着待ち"))
            }
        case .fired:
            if let firedAt = shared.firedAt {
                Text("\(String(localized: "到着")) \(dayAndTimeText(firedAt))")
            } else {
                Text(String(localized: "到着済み・完了待ち"))
            }
        case .completed:
            if let completedAt = shared.completedAt {
                Text("\(String(localized: "完了")) \(dayAndTimeText(completedAt))")
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
            let service = CKShareService.shared
            let sentData = try await service.fetchSentSharedMemos()
            var didChange = false
            var tracked: [SharedMemoCKData] = []
            for data in sentData {
                let recordName = data.ckRecordID.recordName
                guard let local = allSharedMemos.first(where: { $0.ckRecordName == recordName }) else { continue }
                tracked.append(data)
                if local.apply(data) { didChange = true }
                // 完了・取り消しになった依頼の本文は端末に残さない
                if local.status.isTerminal {
                    SharedMemoNoteStore.setNote("", for: recordName)
                }
            }

            // 受信者は、共有を受諾した参加者（CloudKit が保証する本人）から決める。
            // レコードの受信者名・ID は相手が自由に書けるので、そのままは信用しない。
            if let recipients = try? await service.fetchVerifiedRecipients(for: tracked) {
                let tombstones = FriendTombstoneStore.shared
                let verified = VerifiedFriendStore.shared
                let unsent = UnsentShareStore.shared
                for (recordName, resolved) in recipients {
                    guard let local = allSharedMemos.first(where: { $0.ckRecordName == recordName }) else { continue }
                    let recipient = resolved.recipient
                    let result = local.applyVerifiedRecipient(recipient)
                    if result.changed { didChange = true }
                    // 誰かが受け取ったので「未送信」ではない
                    unsent.remove(recordName)

                    // 旧版の公開リンクの共有は、表示にだけ使う（フレンドの登録・確認には使わない）
                    guard !resolved.isPublicShare else { continue }
                    // 新しく受信者が決まったときだけ、相手をフレンドに登録する（双方向）。
                    // 削除したフレンドは、削除後に自分で招待して送った依頼のときだけ登録し直す。
                    switch FriendAutoRegistrationPolicy.decide(
                        isPublicShare: resolved.isPublicShare,
                        isNewRecipient: result.isNewRecipient,
                        requestSentAt: local.createdAt,
                        tombstonedAt: tombstones.deletedAt(recipient.userRecordName)
                    ) {
                    case .skip:
                        break
                    case .registerClearingTombstone:
                        tombstones.remove(recipient.userRecordName)
                        fallthrough
                    case .register:
                        if FriendConnection.registerIfNeeded(recordID: recipient.userRecordName,
                                                             displayName: recipient.displayName,
                                                             in: modelContext, tombstones: tombstones,
                                                             verified: verified) {
                            didChange = true
                        }
                    }
                    // CloudKit の名前が分かれば、既存のフレンドの名前をそれに合わせて「確認済み」にする
                    if recipient.nameIsFromCloudKit,
                       FriendConnection.confirmIdentity(recordID: recipient.userRecordName,
                                                        cloudKitName: recipient.displayName,
                                                        in: modelContext, verified: verified) {
                        didChange = true
                    }
                }
                refreshUnsent()
            }
            if didChange { try? modelContext.save() }
        } catch {
            ToastCenter.shared.show(.warning(
                String(localized: "最新の状態を取得できませんでした。通信状況を確認してください。")
            ))
        }
    }

    // MARK: - Resend link

    /// 共有を公開リンクに戻さずに送り直す。
    /// - 招待済みの相手がいる共有: その URL を送る（開けるのは招待済みの相手だけ）。
    /// - 招待済みの相手がいない共有: システムの共有シートで招待し直す。
    /// - 旧版で作った公開リンクの共有: 権限は変えずに同じ URL を送る（docs/sharing.md の制限事項）。
    private func resend(_ shared: SharedMemo) async {
        do {
            let service = CKShareService.shared
            let (method, share) = try await service.resendMethod(for: shared.cloudKitRecordID)
            let content: ShareActivityContent
            switch method {
            case .legacyPublicURL(let url), .invitedURL(let url):
                content = .url(url)
            case .systemInvite:
                content = .cloudKitInvite(share, service.container)
            }
            let recordName = shared.ckRecordName
            let presented = ShareActivityPresenter.present(content) { outcome in
                // 送り直せたら「未送信」ではなくなる
                if outcome == .sent {
                    UnsentShareStore.shared.remove(recordName)
                    refreshUnsent()
                }
            }
            if presented { return }
        } catch {}
        ToastCenter.shared.show(.warning(
            String(localized: "共有リンクを取得できませんでした。通信状況を確認してください。")
        ))
    }

    // MARK: - Cancel

    private func cancelSharedMemo(_ shared: SharedMemo) async {
        do {
            // 相手が先に完了していれば、取り消しは書き込まれず完了のまま（サーバの状態に合わせる）
            let serverStatus = try await CKShareService.shared.cancelSharedMemo(recordID: shared.cloudKitRecordID)
            shared.status = serverStatus.isTerminal ? serverStatus : .cancelled
            SharedMemoNoteStore.setNote("", for: shared.ckRecordName)
            UnsentShareStore.shared.remove(shared.ckRecordName)
            refreshUnsent()
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

// MARK: - Delete unsent

extension WatchDashboardView {
    /// 「未送信」の依頼を削除する。相手に届いていなければサーバのレコードと共有を消す。
    /// 受諾した人・招待中の人がいれば（リンクが届いているかもしれないので）消さずに取り消す。
    fileprivate func deleteUnsent(_ shared: SharedMemo) async {
        let service = CKShareService.shared
        let recordName = shared.ckRecordName
        do {
            switch try await service.deleteUnsentShare(recordID: shared.cloudKitRecordID, shareID: nil,
                                                       allowedInviteeRecordName: nil) {
            case .deleted:
                modelContext.delete(shared)
            case .hasParticipants:
                let serverStatus = try await service.cancelSharedMemo(recordID: shared.cloudKitRecordID)
                shared.status = serverStatus.isTerminal ? serverStatus : .cancelled
            }
            SharedMemoNoteStore.setNote("", for: recordName)
            UnsentShareStore.shared.remove(recordName)
            refreshUnsent()
            try? modelContext.save()
        } catch {
            ToastCenter.shared.show(.warning(
                String(localized: "依頼を削除できませんでした。通信状況を確認してください。")
            ))
        }
    }
}

// MARK: - 送信後の編集（依頼者）

/// 送った依頼のタイトル・本文・期限を編集する。保存すると受信側の次回同期で反映される。
/// 監視中 (active) の依頼だけを編集できる（サーバ側でも確認する）。
private struct EditSharedMemoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let shared: SharedMemo

    @State private var title = ""
    @State private var note = ""
    @State private var hasDeadline = false
    @State private var deadline = Date()
    @State private var isSaving = false
    /// 本文の読み込み状態。本文は端末のキャッシュに無いことがある（別の端末で送った、再インストール等）ので、
    /// 開くたびにサーバから読む。読めなかったときは本文を書き込まない（空で上書きしない）。
    @State private var noteState: NoteState = .loading
    /// 本文をどこから読んだか。キャッシュから出した本文は、書き換えたときだけ保存する。
    @State private var noteSource: SharedMemoNoteEditPolicy.Source = .unavailable
    /// 読み込んだときの本文（書き換えたかどうかの判定用）
    @State private var loadedNote = ""

    private enum NoteState { case loading, loaded, unavailable }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "タイトル")) {
                    TextField(String(localized: "タイトル"), text: $title)
                }
                Section {
                    switch noteState {
                    case .loading:
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .loaded:
                        TextField(String(localized: "メモ"), text: $note, axis: .vertical)
                            .lineLimit(3...8)
                        if noteSource == .cache {
                            Text(String(localized: "最新の本文を読み込めなかったため、この端末に保存した本文を表示しています。本文は書き換えたときだけ保存されます。"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    case .unavailable:
                        Text(String(localized: "本文を読み込めませんでした。本文は変更されません。"))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(String(localized: "メモ"))
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
                            .disabled(noteState == .loading)
                    }
                }
            }
            .onAppear {
                title = shared.memoTitle
                hasDeadline = shared.memoDeadline != nil
                deadline = shared.memoDeadline ?? Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            }
            .task { await loadNote() }
        }
    }

    /// サーバから現在の本文を読む。読めなければ端末のキャッシュ、それも無ければ「不明」にする。
    private func loadNote() async {
        if let data = try? await CKShareService.shared.fetchSentSharedMemo(recordID: shared.cloudKitRecordID) {
            note = data.memoNote
            loadedNote = data.memoNote
            noteSource = .server
            noteState = .loaded
            SharedMemoNoteStore.setNote(data.memoNote, for: shared.ckRecordName)
            return
        }
        let cached = SharedMemoNoteStore.note(for: shared.ckRecordName)
        if cached.isEmpty {
            noteSource = .unavailable
            noteState = .unavailable
        } else {
            note = cached
            loadedNote = cached
            noteSource = .cache
            noteState = .loaded
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let newDeadline = hasDeadline ? deadline : nil
        // 本文が分からないとき、キャッシュの本文を書き換えていないときは nil を渡し、サーバの本文を変えない
        let newNote = SharedMemoNoteEditPolicy.noteToSave(source: noteSource, loaded: loadedNote, current: note)
        do {
            try await CKShareService.shared.updateSharedMemoContent(
                recordID: shared.cloudKitRecordID, title: title, note: newNote, deadline: newDeadline)
            shared.memoTitle = title
            shared.memoDeadline = newDeadline
            if let newNote {
                SharedMemoNoteStore.setNote(newNote, for: shared.ckRecordName)
            }
            try? modelContext.save()
            dismiss()
        } catch CKShareService.ServiceError.notEditable {
            ToastCenter.shared.show(.warning(
                String(localized: "相手が到着したか取り消されたため、この依頼は編集できなくなりました。")
            ))
            dismiss()
        } catch {
            ToastCenter.shared.show(.warning(
                String(localized: "依頼を更新できませんでした。通信状況を確認してください。")
            ))
        }
    }
}

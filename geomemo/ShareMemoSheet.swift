import SwiftUI
import SwiftData
import CloudKit
import os

// MARK: - メモ依頼シート

struct ShareMemoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let memo: GeoMemo

    @Query(sort: \FriendConnection.createdAt) private var connections: [FriendConnection]
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]

    private var myProfile: UserProfile? { profiles.first }
    private var acceptedFriends: [FriendConnection] {
        FriendConnection.deduplicated(connections.filter { $0.status == .accepted })
    }

    @State private var selectedFriend: FriendConnection?
    /// フレンド以外の相手を招待して送る。フレンドは共有の受諾時にしか増えないため、
    /// 最初の 1 人目はこの経路で送る (受け取った側で送り主がフレンド登録される)。
    /// システムの共有シートで選んだ相手だけが参加できる（リンクを転送されても他人は開けない）。
    @State private var sendViaLink = false
    private var hasRecipient: Bool { selectedFriend != nil || sendViaLink }
    @State private var autoComplete: Bool = false
    @State private var isSending = false
    @State private var errorMessage: String?
    /// CloudKit の情報で本人を確かめたフレンド（それ以外は「未確認」と表示し、送る前に確認する）
    @State private var verifiedFriendIDs: Set<String> = []
    /// 未確認のフレンドへ送る前の確認
    @State private var unverifiedFriendToConfirm: FriendConnection?

    private func isUnverified(_ friend: FriendConnection) -> Bool {
        !verifiedFriendIDs.contains(friend.friendRecordID)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // メモプレビュー
                memoPreview
                    .padding(16)

                Rectangle()
                    .fill(Brand.separator)
                    .frame(height: 1)

                ScrollView {
                    VStack(spacing: 20) {

                        // フレンド選択
                        friendPickerSection

                        // 相手に見える内容 / あなたに届く内容 / 開ける人
                        explanationSection

                        // オプション
                        optionSection

                        if myProfile == nil {
                            // 表示名が無いと送信できない (ボタンが無反応に見えるのを防ぐ)
                            Text(String(localized: "依頼を送るには、設定の「フレンド」で表示名を設定してください。"))
                                .font(.footnote)
                                .foregroundStyle(Brand.secondaryText)
                                .padding(.horizontal, 20)
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 20)
                        }
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .background(Brand.background)
            .navigationTitle(String(localized: "依頼する"))
            .onAppear {
                if acceptedFriends.isEmpty { sendViaLink = true }
                verifiedFriendIDs = VerifiedFriendStore.shared.all
            }
            .confirmationDialog(
                unverifiedFriendToConfirm.map {
                    String(localized: "「\($0.friendDisplayName)」に送りますか？")
                } ?? "",
                isPresented: Binding(
                    get: { unverifiedFriendToConfirm != nil },
                    set: { if !$0 { unverifiedFriendToConfirm = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(String(localized: "送る")) {
                    unverifiedFriendToConfirm = nil
                    performSend()
                }
                Button(String(localized: "キャンセル"), role: .cancel) {
                    unverifiedFriendToConfirm = nil
                }
            } message: {
                Text(String(localized: "このフレンドは以前のバージョンで登録されたため、名前が本人のものか確認できていません。相手が本人であることを確かめてから送ってください。"))
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "キャンセル")) { dismiss() }
                        .foregroundStyle(Brand.primaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: send) {
                        if isSending {
                            ProgressView()
                        } else {
                            Text(String(localized: "依頼を送る"))
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .disabled(!hasRecipient || isSending || myProfile == nil)
                    .foregroundStyle(hasRecipient && myProfile != nil ? Brand.blue : Brand.secondaryText)
                    .accessibilityLabel(isSending
                        ? String(localized: "送信中")
                        : String(localized: "依頼を送る"))
                }
            }
        }
    }

    // MARK: - メモプレビュー

    private var memoPreview: some View {
        HStack(spacing: 14) {
            Image(systemName: "mappin.circle.fill")
                .font(.title)
                .foregroundStyle(Brand.blue)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(memo.displayTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                    .lineLimit(2)
                Text(memo.locationName)
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Brand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    // MARK: - フレンド選択

    private var friendPickerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "送る相手"))

            linkRecipientRow
                .padding(.bottom, acceptedFriends.isEmpty ? 0 : 12)

            if acceptedFriends.isEmpty {
                Text(String(localized: "共有を受け取った相手は、次回からフレンドとしてここに表示されます。"))
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(acceptedFriends) { friend in
                        Button {
                            HapticManager.selection()
                            selectedFriend = friend
                            sendViaLink = false
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: selectedFriend?.id == friend.id
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selectedFriend?.id == friend.id
                                                     ? Brand.blue : Brand.primaryText.opacity(0.3))
                                    .accessibilityHidden(true)

                                Text(friend.friendDisplayName)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Brand.primaryText)
                                if isUnverified(friend) {
                                    UnverifiedFriendBadge()
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .accessibilityLabel(isUnverified(friend)
                            ? String(localized: "\(friend.friendDisplayName)、未確認")
                            : friend.friendDisplayName)
                        .accessibilityAddTraits(selectedFriend?.id == friend.id ? .isSelected : [])
                        if friend.id != acceptedFriends.last?.id {
                            Rectangle()
                                .fill(Brand.separator)
                                .frame(height: 1)
                                .padding(.leading, 56)
                        }
                    }
                }
                .background(Brand.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
            }
        }
    }

    /// フレンド以外 (まだフレンドでない相手) にリンクで送る行。
    private var linkRecipientRow: some View {
        Button {
            HapticManager.selection()
            sendViaLink = true
            selectedFriend = nil
        } label: {
            HStack(spacing: 14) {
                Image(systemName: sendViaLink ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(sendViaLink ? Brand.blue : Brand.primaryText.opacity(0.3))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "リンクで送る"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                    Text(String(localized: "共有シートで選んだ相手だけが受け取れます。メッセージやメールでの送信をおすすめします。LINE など、宛先の相手を特定できないアプリでは受け取れないことがあります。"))
                        .font(.caption)
                        .foregroundStyle(Brand.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "link")
                    .foregroundStyle(Brand.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Brand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .accessibilityLabel(String(localized: "リンクで送る"))
        .accessibilityAddTraits(sendViaLink ? .isSelected : [])
    }

    // MARK: - 説明

    private var explanationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "送る前に"))

            VStack(alignment: .leading, spacing: 14) {
                explanationRow(
                    icon: "eye",
                    title: String(localized: "相手に見える内容"),
                    body: visibleContentBody)
                explanationRow(
                    icon: "bell",
                    title: String(localized: "あなたに届く内容"),
                    body: String(localized: "相手が場所に着いたときと、完了にしたときに通知が届きます。相手の現在地は共有されません。"))
                explanationRow(
                    icon: "lock",
                    title: String(localized: "開ける人"),
                    body: String(localized: "送った相手だけが開けます。リンクを転送された別の人は開けません。"))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }

    /// 相手に見える内容。時間帯が設定されていれば範囲も明示する。
    private var visibleContentBody: String {
        if let start = memo.timeWindowStart, let end = memo.timeWindowEnd {
            return String(localized: "メモのタイトル・メモ・場所・範囲・期限・時間帯（\(Self.clock(start))〜\(Self.clock(end))）と、あなたの表示名が見えます。")
        }
        return String(localized: "メモのタイトル・メモ・場所・範囲・期限と、あなたの表示名が見えます。")
    }

    private static func clock(_ minutes: Int) -> String {
        String(format: "%d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    private func explanationRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Brand.blue)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - オプション

    private var optionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "オプション"))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "現地到着で自動完了"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                    Text(String(localized: "ONにすると、相手が着いた時点で自動的に完了にします"))
                        .font(.caption)
                        .foregroundStyle(Brand.secondaryText)
                }
                Spacer(minLength: 8)
                Toggle(String(localized: "現地到着で自動完了"), isOn: $autoComplete)
                    .labelsHidden()
                    .tint(Brand.blue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Brand.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Brand.secondaryText)
            .tracking(0.8)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - 送信

    /// 未確認のフレンドに送るときは、先に確認する（docs/sharing.md「本人確認できていないフレンド」）。
    private func send() {
        guard hasRecipient, myProfile != nil else { return }
        if let friend = selectedFriend, isUnverified(friend) {
            unverifiedFriendToConfirm = friend
            return
        }
        performSend()
    }

    /// 依頼のレコードと非公開の共有を作り、システムの共有シートで送る。
    /// - フレンド: 相手を参加者に加えた共有の URL を送る（その相手しか開けない）。
    /// - 新しい相手（またはフレンドを参加者として引けなかったとき）: 共有シートで相手を招待する。
    /// 共有シートの結果（`ShareSheetOutcome`）で、作ったレコードと共有をどうするか決める。
    /// - 送った: ローカルに保存する。
    /// - 何も送らずに閉じた: サーバから消す（消せなければ次回の起動で消し直す）。
    /// - 送れたか分からない: 消さずにローカルに保存し、見守り画面に「未送信」として出す。
    private func performSend() {
        guard hasRecipient, let profile = myProfile else { return }
        let friend = selectedFriend
        isSending = true
        errorMessage = nil

        Task {
            let service = CKShareService.shared
            let prepared: CKShareService.PreparedShare
            do {
                prepared = try await service.createSharedMemoShare(
                    from: memo,
                    requesterName: profile.displayName,
                    friendRecordName: friend?.friendRecordID,
                    friendName: friend?.friendDisplayName,
                    autoComplete: autoComplete
                )
            } catch {
                errorMessage = String(localized: "送信に失敗しました。もう一度お試しください。")
                isSending = false
                return
            }

            let recordID = prepared.record.recordID
            let recordName = recordID.recordName
            let content: ShareActivityContent
            if prepared.invitedFriend, let url = prepared.share.url {
                content = .url(url)
            } else {
                content = .cloudKitInvite(prepared.share, service.container)
            }
            let recipient = prepared.invitedFriend ? friend : nil
            // 共有シートの表示中にアプリが終了されても、次回の起動で後片付けできるよう記録しておく
            let store = UnsentShareStore.shared
            let entry = UnsentShareEntry(
                recordName: recordName,
                shareRecordName: prepared.share.recordID.recordName,
                invitedFriendRecordName: recipient?.friendRecordID ?? "",
                createdAt: Date(),
                state: .presenting
            )
            store.upsert(entry)
            let saveLocally = {
                saveLocalSharedMemo(recordID: recordID, profile: profile,
                                    recipient: recipient, placeholderName: friend?.friendDisplayName)
            }

            let presented = ShareActivityPresenter.present(content) { outcome in
                switch outcome {
                case .sent:
                    // 「分からない」と判断した後に送信完了が届いた場合は、未送信の印を外すだけ
                    let alreadySaved = store.entry(for: recordName)?.state == .kept
                    store.remove(recordName)
                    guard !alreadySaved else { return }
                    isSending = false
                    saveLocally()
                    HapticManager.notification(.success)
                    dismiss()
                case .notSent:
                    isSending = false
                    discardUnsentShare(entry, saveLocally: saveLocally)
                case .unknown:
                    isSending = false
                    store.setState(.kept, for: recordName)
                    saveLocally()
                    ToastCenter.shared.show(.warning(String(localized:
                        "送信できたか確認できませんでした。見守り画面に「未送信」として残しています。")))
                    dismiss()
                }
            }
            if !presented {
                discardUnsentShare(entry, saveLocally: saveLocally)
                errorMessage = String(localized: "送信に失敗しました。もう一度お試しください。")
                isSending = false
            }
        }
    }

    /// 送信後、ローカルキャッシュへ保存する。
    /// - Parameters:
    ///   - recipient: 参加者として加えたフレンド。招待で送った場合は nil（相手が受け取ったら決まる）。
    ///   - placeholderName: 受信者が決まるまで見守り画面に出す名前。
    private func saveLocalSharedMemo(recordID: CKRecord.ID, profile: UserProfile,
                                     recipient: FriendConnection?, placeholderName: String?) {
        let sharedMemo = SharedMemo(
            ckRecordName:        recordID.recordName,
            memoTitle:           memo.title,
            memoLocationName:    memo.locationName,
            memoLatitude:        memo.latitude,
            memoLongitude:       memo.longitude,
            memoRadius:          memo.radius,
            memoDeadline:        memo.deadline,
            memoTimeWindowStart: memo.timeWindowStart,
            memoTimeWindowEnd:   memo.timeWindowEnd,
            requesterRecordID:   profile.iCloudRecordID,
            requesterName:       profile.displayName,
            recipientRecordID:   recipient?.friendRecordID ?? "",
            recipientName:       recipient?.friendDisplayName ?? placeholderName ?? String(localized: "リンクで共有"),
            autoComplete:        autoComplete,
            isMyRequest:         true
        )
        SharedMemoNoteStore.setNote(memo.note, for: recordID.recordName)
        modelContext.insert(sharedMemo)
        try? modelContext.save()
    }

    /// 共有シートを送らずに閉じたら、サーバに作ったレコードと共有を消す。
    /// 消せなかった（通信エラー等）ときは記録を残し、次回の起動で消し直す。
    /// 受諾した人・招待中の人がいて消さなかったときは、ローカルに「未送信」として残す。
    private func discardUnsentShare(_ entry: UnsentShareEntry, saveLocally: @escaping () -> Void) {
        let store = UnsentShareStore.shared
        store.setState(.discarding, for: entry.recordName)
        let zoneID = CKRecordZone.ID(zoneName: CKShareService.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: entry.recordName, zoneID: zoneID)
        let shareID = CKRecord.ID(recordName: entry.shareRecordName, zoneID: zoneID)
        let allowed = entry.invitedFriendRecordName.isEmpty ? nil : entry.invitedFriendRecordName
        Task {
            do {
                switch try await CKShareService.shared.deleteUnsentShare(
                    recordID: recordID, shareID: shareID, allowedInviteeRecordName: allowed) {
                case .deleted:
                    store.remove(entry.recordName)
                case .hasParticipants:
                    store.setState(.kept, for: entry.recordName)
                    saveLocally()
                }
            } catch {
                CKShareService.logger.error("unsent share cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// 本人確認できていないフレンドに付ける印
struct UnverifiedFriendBadge: View {
    var body: some View {
        Text(String(localized: "未確認"))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Brand.warning)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }
}

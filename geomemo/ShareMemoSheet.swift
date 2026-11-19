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
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .accessibilityLabel(friend.friendDisplayName)
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
                    Text(String(localized: "共有シートで選んだ相手だけが受け取れます"))
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

    // MARK: - オプション

    private var optionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "オプション"))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "現地到着で自動完了"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                    Text(String(localized: "ONにすると発火と同時に完了通知を送ります"))
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

    /// 依頼のレコードと非公開の共有を作り、システムの共有シートで送る。
    /// - フレンド: 相手を参加者に加えた共有の URL を送る（その相手しか開けない）。
    /// - 新しい相手（またはフレンドを参加者として引けなかったとき）: 共有シートで相手を招待する。
    /// 共有シートを送らずに閉じたら、作ったレコードと共有を消す。
    private func send() {
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
            let shareID = prepared.share.recordID
            let content: ShareActivityContent
            if prepared.invitedFriend, let url = prepared.share.url {
                content = .url(url)
            } else {
                content = .cloudKitInvite(prepared.share, service.container)
            }
            let recipient = prepared.invitedFriend ? friend : nil
            let presented = ShareActivityPresenter.present(content) { completed in
                isSending = false
                if completed {
                    saveLocalSharedMemo(recordID: recordID, profile: profile,
                                        recipient: recipient, placeholderName: friend?.friendDisplayName)
                    HapticManager.notification(.success)
                    dismiss()
                } else {
                    discardUnsentShare(recordID: recordID, shareID: shareID)
                }
            }
            if !presented {
                discardUnsentShare(recordID: recordID, shareID: shareID)
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
    private func discardUnsentShare(recordID: CKRecord.ID, shareID: CKRecord.ID) {
        Task {
            do {
                try await CKShareService.shared.deleteUnsentShare(recordID: recordID, shareID: shareID)
            } catch {
                CKShareService.logger.error("unsent share cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}


import SwiftUI
import SwiftData
import CloudKit

// MARK: - メモ依頼シート

struct ShareMemoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let memo: GeoMemo

    @Query(sort: \FriendConnection.createdAt) private var connections: [FriendConnection]
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]

    private var myProfile: UserProfile? { profiles.first }
    private var acceptedFriends: [FriendConnection] {
        connections.filter { $0.status == .accepted }
    }

    @State private var selectedFriend: FriendConnection?
    @State private var autoComplete: Bool = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var shareWrapper: ShareWrapper?
    @State private var pendingSharedMemoRecordID: CKRecord.ID?

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
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $shareWrapper) { wrapper in
                CloudSharingControllerSheet(
                    share: wrapper.share,
                    container: wrapper.container
                ) { didShare in
                    if didShare {
                        saveLocalSharedMemo()
                        HapticManager.notification(.success)
                        dismiss()
                    } else {
                        // ユーザーがキャンセル → 作成したCKレコードもクリーンアップする
                        cleanupCancelledShare()
                    }
                }
            }
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
                    .disabled(selectedFriend == nil || isSending || myProfile == nil)
                    .foregroundStyle(selectedFriend != nil ? Brand.blue : Brand.secondaryText)
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

            if acceptedFriends.isEmpty {
                HStack {
                    Image(systemName: "person.2.slash")
                        .foregroundStyle(Brand.secondaryText)
                        .accessibilityHidden(true)
                    Text(String(localized: "フレンドがいません。設定からフレンドを追加してください。"))
                        .font(.subheadline)
                        .foregroundStyle(Brand.secondaryText)
                }
                .padding(16)
                .background(Brand.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .accessibilityElement(children: .combine)
            } else {
                VStack(spacing: 0) {
                    ForEach(acceptedFriends) { friend in
                        Button {
                            HapticManager.selection()
                            selectedFriend = friend
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

    private func send() {
        guard let friend = selectedFriend, let profile = myProfile else { return }
        isSending = true
        errorMessage = nil

        Task {
            do {
                let (record, share) = try await CKShareService.shared.createSharedMemoShare(
                    from: memo,
                    requesterName: profile.displayName,
                    recipientRecordID: friend.friendRecordID,
                    recipientName: friend.friendDisplayName,
                    autoComplete: autoComplete
                )
                pendingSharedMemoRecordID = record.recordID
                shareWrapper = ShareWrapper(share: share, container: CKShareService.shared.container)
                isSending = false
            } catch {
                errorMessage = String(localized: "送信に失敗しました。もう一度お試しください。")
                isSending = false
            }
        }
    }

    /// CloudSharingController で共有が完了した後、ローカルキャッシュへ保存。
    private func saveLocalSharedMemo() {
        guard let friend = selectedFriend, let profile = myProfile,
              let recordID = pendingSharedMemoRecordID else { return }
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
            recipientRecordID:   friend.friendRecordID,
            recipientName:       friend.friendDisplayName,
            autoComplete:        autoComplete,
            isMyRequest:         true
        )
        modelContext.insert(sharedMemo)
        try? modelContext.save()
    }

    /// CloudSharingController で「停止」を選んだ場合、サーバ側の record/share を削除。
    private func cleanupCancelledShare() {
        guard let recordID = pendingSharedMemoRecordID else { return }
        Task {
            _ = try? await CKShareService.shared.privateDB.deleteRecord(withID: recordID)
        }
    }
}

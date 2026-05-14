import SwiftUI
import SwiftData

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // メモプレビュー
                memoPreview
                    .padding(16)

                Rectangle()
                    .fill(Brand.primaryText.opacity(0.08))
                    .frame(height: 1)

                ScrollView {
                    VStack(spacing: 20) {

                        // フレンド選択
                        friendPickerSection

                        // オプション
                        optionSection

                        if let error = errorMessage {
                            Text(error)
                                .font(.system(size: 13))
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
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .disabled(selectedFriend == nil || isSending || myProfile == nil)
                    .foregroundStyle(selectedFriend != nil ? Brand.blue : Brand.secondaryText)
                }
            }
        }
    }

    // MARK: - メモプレビュー

    private var memoPreview: some View {
        HStack(spacing: 14) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Brand.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(memo.displayTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.primaryText)
                    .lineLimit(1)
                Text(memo.locationName)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(14)
        .background(Brand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - フレンド選択

    private var friendPickerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "送る相手"))

            if acceptedFriends.isEmpty {
                HStack {
                    Image(systemName: "person.2.slash")
                        .foregroundStyle(Brand.secondaryText)
                    Text(String(localized: "フレンドがいません。設定からフレンドを追加してください。"))
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.secondaryText)
                }
                .padding(16)
                .background(Brand.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
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
                                    .font(.system(size: 22))
                                    .foregroundStyle(selectedFriend?.id == friend.id
                                                     ? Brand.blue : Brand.primaryText.opacity(0.3))

                                Text(friend.friendDisplayName)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Brand.primaryText)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        if friend.id != acceptedFriends.last?.id {
                            Rectangle()
                                .fill(Brand.primaryText.opacity(0.08))
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
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.primaryText)
                    Text(String(localized: "ONにすると発火と同時に完了通知を送ります"))
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.secondaryText)
                }
                Spacer()
                Toggle("", isOn: $autoComplete)
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
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Brand.secondaryText)
            .tracking(0.8)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    // MARK: - 送信

    private func send() {
        guard let friend = selectedFriend, let profile = myProfile else { return }
        isSending = true
        errorMessage = nil

        Task {
            do {
                let ckName = try await CloudKitShareService.shared.createSharedMemo(
                    from: memo,
                    requesterProfile: profile,
                    recipient: friend,
                    autoComplete: autoComplete
                )

                // ローカルにも保存（見守りダッシュボード用）
                let sharedMemo = SharedMemo(
                    ckRecordName: ckName,
                    memoTitle: memo.title,
                    memoLocationName: memo.locationName,
                    memoLatitude: memo.latitude,
                    memoLongitude: memo.longitude,
                    memoRadius: memo.radius,
                    memoDeadline: memo.deadline,
                    memoTimeWindowStart: memo.timeWindowStart,
                    memoTimeWindowEnd: memo.timeWindowEnd,
                    requesterRecordID: profile.iCloudRecordID,
                    requesterName: profile.displayName,
                    recipientRecordID: friend.friendRecordID,
                    recipientName: friend.friendDisplayName,
                    autoComplete: autoComplete,
                    isMyRequest: true
                )
                modelContext.insert(sharedMemo)
                try modelContext.save()

                HapticManager.notification(.success)
                dismiss()
            } catch {
                errorMessage = String(localized: "送信に失敗しました。もう一度お試しください。")
                isSending = false
            }
        }
    }
}

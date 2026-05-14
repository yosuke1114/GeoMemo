import SwiftUI
import SwiftData

// MARK: - フレンド招待承認シート

struct FriendInvitationAcceptView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let inviteCode: String

    @Query private var profiles: [UserProfile]
    private var myProfile: UserProfile? { profiles.first }

    @State private var requesterName: String = ""
    @State private var requesterID: String = ""
    @State private var isLoading = true
    @State private var isAccepting = false
    @State private var errorMessage: String?
    @State private var isInvalidCode = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if isLoading {
                    ProgressView()
                        .scaleEffect(1.4)
                    Text(String(localized: "招待を確認中..."))
                        .font(.system(size: 15))
                        .foregroundStyle(Brand.secondaryText)

                } else if isInvalidCode {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.red.opacity(0.7))
                    Text(String(localized: "無効な招待リンク"))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Brand.primaryText)
                    Text(String(localized: "このリンクは期限切れか無効です。\n送った相手に再度招待してもらってください。"))
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                } else {
                    Image(systemName: "person.badge.plus.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Brand.blue)

                    VStack(spacing: 8) {
                        Text(String(localized: "フレンド申請"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Brand.secondaryText)
                            .tracking(0.5)

                        Text(requesterName)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Brand.primaryText)

                        Text(String(localized: "さんからフレンド申請が届いています"))
                            .font(.system(size: 15))
                            .foregroundStyle(Brand.secondaryText)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 24)
                    }

                    VStack(spacing: 12) {
                        Button(action: accept) {
                            Group {
                                if isAccepting {
                                    ProgressView().tint(.white)
                                } else {
                                    Text(String(localized: "承認する"))
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Brand.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(isAccepting || myProfile == nil)

                        Button(action: { dismiss() }) {
                            Text(String(localized: "断る"))
                                .font(.system(size: 17))
                                .foregroundStyle(Brand.secondaryText)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }

                Spacer()
            }
            .background(Brand.background)
            .navigationTitle(String(localized: "フレンド申請"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                        .foregroundStyle(Brand.primaryText)
                }
            }
        }
        .task { await loadInvitation() }
    }

    // MARK: - Load

    private func loadInvitation() async {
        do {
            let result = try await CloudKitFriendService.shared.fetchInvitation(code: inviteCode)
            requesterName = result.requesterName
            requesterID   = result.requesterID
        } catch {
            isInvalidCode = true
        }
        isLoading = false
    }

    // MARK: - Accept

    private func accept() {
        guard let profile = myProfile else { return }
        isAccepting = true
        errorMessage = nil

        Task {
            do {
                // 1. Public DB の招待レコードに承認を書き込む
                try await CloudKitFriendService.shared.acceptInvitation(
                    code: inviteCode,
                    myRecordID: profile.iCloudRecordID,
                    myName: profile.displayName
                )

                // 2. 自分の FriendConnection を SwiftData に保存
                let connection = FriendConnection(
                    friendRecordID: requesterID,
                    friendDisplayName: requesterName,
                    status: .accepted
                )
                modelContext.insert(connection)
                try modelContext.save()

                HapticManager.notification(.success)
                dismiss()
            } catch {
                errorMessage = String(localized: "承認に失敗しました。もう一度お試しください。")
                isAccepting = false
            }
        }
    }
}

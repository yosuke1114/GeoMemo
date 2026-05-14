import SwiftUI
import SwiftData

// MARK: - フレンド管理画面

struct FriendManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \FriendConnection.createdAt) private var connections: [FriendConnection]

    private var myProfile: UserProfile? { profiles.first }
    private var acceptedFriends: [FriendConnection] {
        connections.filter { $0.status == .accepted }
    }

    @State private var showProfileSetup = false
    @State private var showShareSheet = false
    @State private var inviteURL: URL?
    @State private var isGeneratingInvite = false
    @State private var inviteError: String?
    @State private var isCheckingAccepted = false

    private var iCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if !iCloudAvailable {
                    iCloudUnavailableView
                } else if myProfile == nil {
                    profileNotSetView
                } else {
                    mainContentView
                }
            }
            .background(Brand.background)
            .navigationTitle(String(localized: "フレンド管理"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "完了")) { dismiss() }
                        .foregroundStyle(Brand.primaryText)
                }
            }
        }
        .sheet(isPresented: $showProfileSetup) {
            UserProfileSetupView()
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = inviteURL {
                ShareSheet(items: [url])
            }
        }
        .task {
            if myProfile != nil {
                await checkAcceptedInvitations()
            }
        }
    }

    // MARK: - iCloud 未サインイン

    private var iCloudUnavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 48))
                .foregroundStyle(Brand.secondaryText.opacity(0.5))
            Text(String(localized: "iCloudサインインが必要です"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Brand.primaryText)
            Text(String(localized: "設定 → Apple ID からiCloudにサインインしてください。"))
                .font(.system(size: 14))
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            } label: {
                Text(String(localized: "設定を開く"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 160, height: 44)
                    .background(Brand.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - プロフィール未設定

    private var profileNotSetView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.circle")
                .font(.system(size: 48))
                .foregroundStyle(Brand.blue.opacity(0.5))
            Text(String(localized: "プロフィールを設定してください"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Brand.primaryText)
            Text(String(localized: "フレンド機能を使うには表示名の設定が必要です。"))
                .font(.system(size: 14))
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showProfileSetup = true
            } label: {
                Text(String(localized: "プロフィールを設定"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 200, height: 44)
                    .background(Brand.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - メインコンテンツ

    private var mainContentView: some View {
        ScrollView {
            VStack(spacing: 20) {

                // 自分のプロフィールカード
                profileCard

                // 招待リンク生成
                inviteSection

                // フレンド一覧
                if !acceptedFriends.isEmpty {
                    friendsListSection
                } else {
                    emptyFriendsView
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .refreshable {
            await checkAcceptedInvitations()
        }
    }

    // MARK: - プロフィールカード

    private var profileCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Brand.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(myProfile?.displayName ?? "")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Brand.primaryText)
                Text(String(localized: "自分のプロフィール"))
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.secondaryText)
            }
            Spacer()
        }
        .padding(16)
        .background(Brand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 招待セクション

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "フレンドを招待"))

            Button(action: generateInviteLink) {
                HStack(spacing: 12) {
                    if isGeneratingInvite {
                        ProgressView()
                            .frame(width: 24)
                    } else {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 18))
                            .foregroundStyle(Brand.blue)
                            .frame(width: 24)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "招待リンクを送る"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Brand.primaryText)
                        Text(String(localized: "リンクを開いた相手がフレンドになります（48時間有効）"))
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.secondaryText)
                }
                .padding(16)
            }
            .disabled(isGeneratingInvite)

            if let error = inviteError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .background(Brand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - フレンド一覧

    private var friendsListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "FRIENDS (\(acceptedFriends.count))"))

            ForEach(acceptedFriends) { friend in
                friendRow(friend)
                if friend.id != acceptedFriends.last?.id {
                    Rectangle()
                        .fill(Brand.primaryText.opacity(0.08))
                        .frame(height: 1)
                        .padding(.leading, 60)
                }
            }
        }
        .background(Brand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func friendRow(_ friend: FriendConnection) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Brand.blue.opacity(0.7))
                .frame(width: 36)

            Text(friend.friendDisplayName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.primaryText)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteFriend(friend)
            } label: {
                Label(String(localized: "削除"), systemImage: "trash")
            }
        }
    }

    // MARK: - フレンドなし

    private var emptyFriendsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 36))
                .foregroundStyle(Brand.secondaryText.opacity(0.4))
                .padding(.top, 24)
            Text(String(localized: "まだフレンドがいません"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.primaryText)
            Text(String(localized: "招待リンクを送ってフレンドを追加しましょう。\n下に引いて更新すると新しいフレンドが表示されます。"))
                .font(.system(size: 13))
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(Brand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Brand.secondaryText)
            .tracking(0.8)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
    }

    // MARK: - 招待リンク生成

    private func generateInviteLink() {
        guard let profile = myProfile else { return }
        isGeneratingInvite = true
        inviteError = nil

        Task {
            do {
                let code = UUID().uuidString
                try await CloudKitFriendService.shared.createInvitation(
                    code: code,
                    myRecordID: profile.iCloudRecordID,
                    myName: profile.displayName
                )
                let url = URL(string: "geomemo://friend/\(code)")!
                await MainActor.run {
                    inviteURL = url
                    showShareSheet = true
                    isGeneratingInvite = false
                }
            } catch {
                await MainActor.run {
                    inviteError = String(localized: "招待リンクの生成に失敗しました。")
                    isGeneratingInvite = false
                }
            }
        }
    }

    // MARK: - 承認済み招待の確認（pull-to-refresh）

    private func checkAcceptedInvitations() async {
        guard let profile = myProfile else { return }
        isCheckingAccepted = true

        do {
            let accepted = try await CloudKitFriendService.shared
                .fetchAcceptedInvitations(myRecordID: profile.iCloudRecordID)

            for item in accepted {
                // すでにフレンドとして登録済みでなければ追加
                let alreadyExists = connections.contains { $0.friendRecordID == item.accepterID }
                if !alreadyExists {
                    let connection = FriendConnection(
                        friendRecordID: item.accepterID,
                        friendDisplayName: item.accepterName,
                        status: .accepted
                    )
                    modelContext.insert(connection)
                    HapticManager.notification(.success)
                }
                // 処理済みの招待レコードを Public DB から削除
                try? await CloudKitFriendService.shared.deleteInvitation(code: item.code)
            }
            try? modelContext.save()
        } catch {
            // ネットワークエラー等は静かに無視
        }
        isCheckingAccepted = false
    }

    // MARK: - フレンド削除

    private func deleteFriend(_ friend: FriendConnection) {
        HapticManager.notification(.warning)
        modelContext.delete(friend)
        try? modelContext.save()
    }
}

// MARK: - ShareSheet Wrapper

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

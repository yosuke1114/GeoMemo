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
        FriendConnection.deduplicated(connections.filter { $0.status == .accepted })
    }

    @State private var showProfileSetup = false
    /// CloudKit の情報で本人を確かめたフレンド（それ以外は「未確認」と表示する）
    @State private var verifiedFriendIDs: Set<String> = []

    private func isUnverified(_ friend: FriendConnection) -> Bool {
        !verifiedFriendIDs.contains(friend.friendRecordID)
    }

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
        .onAppear {
            verifiedFriendIDs = VerifiedFriendStore.shared.all
            // 複数端末の CloudKit ミラーリングで同じ相手が重複登録されていたら片付ける
            if FriendConnection.removeDuplicates(in: modelContext) {
                try? modelContext.save()
            }
        }
    }

    // MARK: - iCloud 未サインイン

    private var iCloudUnavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "icloud.slash")
                .font(.system(size: emptyStateIconSize))
                .foregroundStyle(Brand.secondaryText.opacity(0.5))
                .accessibilityHidden(true)
            Text(String(localized: "iCloudサインインが必要です"))
                .font(.body.weight(.semibold))
                .foregroundStyle(Brand.primaryText)
            Text(String(localized: "設定 → Apple ID からiCloudにサインインしてください。"))
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            } label: {
                Text(String(localized: "設定を開く"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(minWidth: 160, minHeight: 44)
                    .background(Brand.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ScaledMetric(relativeTo: .largeTitle) private var emptyStateIconSize: CGFloat = 48

    // MARK: - プロフィール未設定

    private var profileNotSetView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.circle")
                .font(.system(size: emptyStateIconSize))
                .foregroundStyle(Brand.blue.opacity(0.5))
                .accessibilityHidden(true)
            Text(String(localized: "プロフィールを設定してください"))
                .font(.body.weight(.semibold))
                .foregroundStyle(Brand.primaryText)
            Text(String(localized: "フレンド機能を使うには表示名の設定が必要です。"))
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showProfileSetup = true
            } label: {
                Text(String(localized: "プロフィールを設定"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(minWidth: 200, minHeight: 44)
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

                // フレンド一覧
                if !acceptedFriends.isEmpty {
                    friendsListSection
                    if acceptedFriends.contains(where: isUnverified) {
                        Text(String(localized: "「未確認」のフレンドは以前のバージョンで登録されたため、名前が本人のものか確認できていません。相手から依頼を受け取ると確認済みになります。"))
                            .font(.footnote)
                            .foregroundStyle(Brand.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                } else {
                    emptyFriendsView
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
    }

    // MARK: - プロフィールカード

    private var profileCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(Brand.blue)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(myProfile?.displayName ?? "")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                Text(String(localized: "自分のプロフィール"))
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Brand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "自分のプロフィール、\(myProfile?.displayName ?? "")"))
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
                .font(.title)
                .foregroundStyle(Brand.blue.opacity(0.7))
                .frame(minWidth: 36)
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
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isUnverified(friend)
            ? String(localized: "\(friend.friendDisplayName)、未確認")
            : friend.friendDisplayName)
        // ScrollView/VStack 内では .swipeActions が動かないため長押しメニューで代替。
        .contextMenu {
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
                .font(.title)
                .foregroundStyle(Brand.secondaryText.opacity(0.4))
                .padding(.top, 24)
                .accessibilityHidden(true)
            Text(String(localized: "まだフレンドがいません"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.primaryText)
            Text(String(localized: "メモの詳細から「依頼する」→「リンクで送る」で共有すると、\n受け取った相手とフレンドになります。"))
                .font(.footnote)
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
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Brand.secondaryText)
            .tracking(0.8)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - フレンド削除

    /// 重複分も含めて削除し、削除の記録を残す（依頼の同期による自動登録で戻らないように）。
    private func deleteFriend(_ friend: FriendConnection) {
        HapticManager.notification(.warning)
        FriendConnection.delete(recordID: friend.friendRecordID, fallback: friend,
                                in: modelContext, tombstones: .shared)
        try? modelContext.save()
    }
}


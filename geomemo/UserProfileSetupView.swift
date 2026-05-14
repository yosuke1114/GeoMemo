import SwiftUI
import SwiftData

// MARK: - UserProfile Setup Sheet

struct UserProfileSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var displayName: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Brand.blue)
                        .padding(.top, 40)

                    Text(String(localized: "プロフィールを設定"))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Brand.primaryText)

                    Text(String(localized: "メモの共有や見守りに使われる表示名を設定してください。"))
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.bottom, 40)

                // Name input
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "表示名"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Brand.secondaryText)
                        .tracking(0.5)
                        .padding(.horizontal, 20)

                    TextField(String(localized: "例：田中 洋輔"), text: $displayName)
                        .font(.system(size: 17))
                        .foregroundStyle(Brand.primaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Brand.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                Spacer()

                // Save button
                Button(action: save) {
                    Group {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text(String(localized: "設定する"))
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(isValid ? Brand.blue : Brand.blue.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!isValid || isLoading)
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Brand.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "キャンセル")) { dismiss() }
                        .foregroundStyle(Brand.primaryText)
                }
            }
        }
    }

    // MARK: - Save

    private func save() {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let recordID = try await CloudKitFriendService.shared.fetchMyRecordID()
                let profile = UserProfile(displayName: trimmed, iCloudRecordID: recordID)
                modelContext.insert(profile)
                try modelContext.save()
                dismiss()
            } catch {
                errorMessage = String(localized: "iCloudの取得に失敗しました。サインイン状態を確認してください。")
                isLoading = false
            }
        }
    }
}

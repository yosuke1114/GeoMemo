import SwiftUI
import SwiftData
import CloudKit

// MARK: - UserProfile Setup Sheet

struct UserProfileSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var displayName: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// プロフィール画面トップの大きな person アイコンを Dynamic Type に追従させる。
    @ScaledMetric(relativeTo: .largeTitle) private var headerIconSize: CGFloat = 56

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: headerIconSize))
                        .foregroundStyle(Brand.blue)
                        .padding(.top, 40)
                        .accessibilityHidden(true)

                    Text(String(localized: "プロフィールを設定"))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Brand.primaryText)
                        .multilineTextAlignment(.center)

                    Text(String(localized: "メモの共有や見守りに使われる表示名を設定してください。"))
                        .font(.subheadline)
                        .foregroundStyle(Brand.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.bottom, 40)

                // Name input
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "表示名"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText)
                        .tracking(0.5)
                        .padding(.horizontal, 20)
                        .accessibilityHidden(true)

                    TextField(String(localized: "例：田中 洋輔"), text: $displayName)
                        .font(.body)
                        .foregroundStyle(Brand.primaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Brand.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                        .accessibilityLabel(String(localized: "表示名"))
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.footnote)
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
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .padding(.vertical, 6)
                    .background(isValid ? Brand.blue : Brand.blue.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!isValid || isLoading)
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
                .accessibilityLabel(isLoading
                    ? String(localized: "保存中")
                    : String(localized: "設定する"))
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
                // CKShare 移行後は、自分の iCloud RecordID をローカルに保存する必要は薄い
                // （CKContainer.userRecordID() を必要時に直接取得すれば十分）。
                // 後方互換のため取得して保存しておく。
                let recordID = try await CKContainer(identifier: geomemoApp.cloudKitContainerID)
                    .userRecordID()
                let profile = UserProfile(displayName: trimmed, iCloudRecordID: recordID.recordName)
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

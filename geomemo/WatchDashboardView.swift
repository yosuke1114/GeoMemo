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

    var body: some View {
        NavigationStack {
            Group {
                if sentMemos.isEmpty {
                    emptyState
                } else {
                    dashboardList
                }
            }
            .background(Brand.background)
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
                    } else {
                        Button {
                            Task { await syncStatus() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(Brand.blue)
                        }
                    }
                }
            }
        }
        .task { await syncStatus() }
    }

    // MARK: - 空状態

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash")
                .font(.system(size: 48))
                .foregroundStyle(Brand.secondaryText.opacity(0.4))
            Text(String(localized: "依頼中のメモはありません"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Brand.primaryText)
            Text(String(localized: "メモ詳細から「依頼する」ボタンで\nフレンドに依頼できます。"))
                .font(.system(size: 14))
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - ダッシュボードリスト

    private var dashboardList: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(groupedByRecipient, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        // 人名ヘッダー
                        HStack(spacing: 8) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Brand.blue)
                            Text(group.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Brand.secondaryText)
                                .tracking(0.5)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

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
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(shared.memoTitle.isEmpty ? String(localized: "（タイトルなし）") : shared.memoTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusTitleColor(for: shared.status))
                    .lineLimit(1)

                statusSubtitle(for: shared)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.secondaryText)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if shared.status == .active {
                Button(role: .destructive) {
                    Task { await cancelSharedMemo(shared) }
                } label: {
                    Label(String(localized: "キャンセル"), systemImage: "xmark")
                }
            }
        }
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
                Text("〜\(deadline, format: .dateTime.hour().minute())")
            } else {
                Text(String(localized: "監視中"))
            }
        case .fired:
            if let firedAt = shared.firedAt {
                Text("\(String(localized: "到着")) \(firedAt, format: .dateTime.hour().minute())")
            } else {
                Text(String(localized: "到着済み・完了待ち"))
            }
        case .completed:
            if let completedAt = shared.completedAt {
                Text("\(String(localized: "完了")) \(completedAt, format: .dateTime.hour().minute())")
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
        defer { isSyncing = false }
        do {
            let sentData = try await CKShareService.shared.fetchSentSharedMemos()
            for data in sentData {
                let recordName = data.ckRecordID.recordName
                if let local = allSharedMemos.first(where: { $0.ckRecordName == recordName }) {
                    local.status      = data.status
                    local.firedAt     = data.firedAt
                    local.completedAt = data.completedAt
                }
            }
            try? modelContext.save()
        } catch { /* ネットワーク不可時は静かに無視 */ }
    }

    // MARK: - Cancel

    private func cancelSharedMemo(_ shared: SharedMemo) async {
        let owner = shared.isMyRequest ? CKCurrentUserDefaultName : shared.requesterRecordID
        let zoneID = CKRecordZone.ID(zoneName: CKShareService.sharingZoneName, ownerName: owner)
        let recordID = CKRecord.ID(recordName: shared.ckRecordName, zoneID: zoneID)
        do {
            try await CKShareService.shared.cancelSharedMemo(recordID: recordID)
            shared.status = .cancelled
            try? modelContext.save()
        } catch {
            PendingEventQueue.shared.enqueue(
                .cancelled(ckRecordName: shared.ckRecordName, zoneOwnerName: owner)
            )
        }
    }
}

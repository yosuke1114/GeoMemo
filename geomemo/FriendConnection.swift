import Foundation
import SwiftData

// MARK: - FriendStatus

enum FriendStatus: String, Codable {
    case pending   // 自分が送った招待・相手未承認
    case accepted  // 承認済み
}

// MARK: - FriendConnection Model

@Model final class FriendConnection {
    var id: UUID = UUID()
    var friendRecordID: String = ""       // 相手の iCloud Record ID
    var friendDisplayName: String = ""
    var statusRaw: String = FriendStatus.pending.rawValue
    var inviteCode: String = ""           // 自分が生成した招待コード（送信者側のみ）
    var createdAt: Date = Date()

    var status: FriendStatus {
        get { FriendStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(
        friendRecordID: String,
        friendDisplayName: String,
        status: FriendStatus = .accepted,
        inviteCode: String = "",
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.friendRecordID = friendRecordID
        self.friendDisplayName = friendDisplayName
        self.statusRaw = status.rawValue
        self.inviteCode = inviteCode
        self.createdAt = createdAt
    }
}

// MARK: - Friend registration

extension FriendConnection {
    /// 相手をフレンドとして登録する（既に登録済みなら何もしない）。
    /// 依頼を受け取ったとき（受信側→依頼者）と、相手が受け取ったと分かったとき（依頼者→受信者）の
    /// 両方から呼び、フレンド関係を双方向にする。`@Query` のスナップショットではなく
    /// FetchDescriptor で直近の永続状態を見て、連続呼び出し時の二重登録を防ぐ。
    @discardableResult
    static func registerIfNeeded(recordID: String, displayName: String, in context: ModelContext) -> Bool {
        guard !recordID.isEmpty else { return false }
        let target = recordID
        var descriptor = FetchDescriptor<FriendConnection>(predicate: #Predicate { $0.friendRecordID == target })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor), !existing.isEmpty { return false }
        context.insert(FriendConnection(
            friendRecordID: recordID,
            friendDisplayName: displayName.isEmpty ? String(localized: "フレンド") : displayName,
            status: .accepted
        ))
        return true
    }
}

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

    init(friendRecordID: String, friendDisplayName: String, status: FriendStatus = .accepted, inviteCode: String = "") {
        self.friendRecordID = friendRecordID
        self.friendDisplayName = friendDisplayName
        self.statusRaw = status.rawValue
        self.inviteCode = inviteCode
    }
}

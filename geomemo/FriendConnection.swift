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
    ///
    /// - Parameters:
    ///   - tombstones: ユーザーが削除したフレンド。含まれる相手は登録しない
    ///     （同期のたびの自動登録で、削除したフレンドが戻らないようにする）。
    ///   - verified: 呼び出し元が CloudKit の情報（共有の所有者・参加者）から相手を決めているなら渡す。
    ///     新しく登録した相手を「確認済み」にする。
    @MainActor @discardableResult
    static func registerIfNeeded(
        recordID: String,
        displayName: String,
        in context: ModelContext,
        tombstones: FriendTombstoneStore? = nil,
        verified: VerifiedFriendStore? = nil
    ) -> Bool {
        guard !recordID.isEmpty else { return false }
        if let tombstones, tombstones.contains(recordID) { return false }
        let target = recordID
        var descriptor = FetchDescriptor<FriendConnection>(predicate: #Predicate { $0.friendRecordID == target })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor), !existing.isEmpty { return false }
        context.insert(FriendConnection(
            friendRecordID: recordID,
            friendDisplayName: displayName.isEmpty ? String(localized: "フレンド") : displayName,
            status: .accepted
        ))
        verified?.add(recordID)
        return true
    }

    /// CloudKit の情報（共有の所有者・参加者）で分かった名前を、既存のフレンドに反映して「確認済み」にする。
    ///
    /// 旧版は相手が書けるレコードのフィールドからフレンドを登録していたため、名前と ID が別人のものでありうる。
    /// CloudKit の名前が分からないときは、名前を確かめられないので何もしない（未確認のまま）。
    /// - Returns: フレンドの名前を変えたら true。
    @MainActor @discardableResult
    static func confirmIdentity(
        recordID: String,
        cloudKitName: String,
        in context: ModelContext,
        verified: VerifiedFriendStore
    ) -> Bool {
        let name = cloudKitName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recordID.isEmpty, !name.isEmpty else { return false }
        let target = recordID
        let matches = (try? context.fetch(FetchDescriptor<FriendConnection>(
            predicate: #Predicate { $0.friendRecordID == target }))) ?? []
        guard !matches.isEmpty else { return false }
        var changed = false
        for friend in matches where friend.friendDisplayName != name {
            friend.friendDisplayName = name
            changed = true
        }
        verified.add(recordID)
        return changed
    }

    /// 同じ相手（`friendRecordID`）の重複を取り除いた一覧。最初に登録したものを残す。
    ///
    /// SwiftData の CloudKit ミラーリングでは、複数端末がそれぞれ同じ相手を登録すると重複する。
    /// どの端末でも同じものを残すよう、作成日時 → id の順で決める。
    static func deduplicated(_ connections: [FriendConnection]) -> [FriendConnection] {
        var seen = Set<String>()
        return connections
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            .filter { connection in
                // ID が空の古いデータは重複判定できないので、そのまま残す
                guard !connection.friendRecordID.isEmpty else { return true }
                return seen.insert(connection.friendRecordID).inserted
            }
    }

    /// 重複しているフレンドを削除する。削除したら true。
    @discardableResult
    static func removeDuplicates(in context: ModelContext) -> Bool {
        guard let all = try? context.fetch(FetchDescriptor<FriendConnection>()) else { return false }
        let keep = Set(deduplicated(all).map(\.persistentModelID))
        let duplicates = all.filter { !keep.contains($0.persistentModelID) }
        duplicates.forEach(context.delete)
        return !duplicates.isEmpty
    }

    /// フレンドを削除する。重複分も含めて消し、自動登録で戻らないよう削除の記録を残す。
    @MainActor
    static func delete(recordID: String, fallback: FriendConnection, in context: ModelContext,
                       tombstones: FriendTombstoneStore) {
        if recordID.isEmpty {
            context.delete(fallback)
            return
        }
        let target = recordID
        let matches = (try? context.fetch(FetchDescriptor<FriendConnection>(
            predicate: #Predicate { $0.friendRecordID == target }))) ?? [fallback]
        matches.forEach(context.delete)
        tombstones.add(recordID)
    }
}

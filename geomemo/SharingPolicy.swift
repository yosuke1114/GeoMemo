import Foundation
import CloudKit

// 依頼の共有（CKShare）まわりの判断を、CloudKit や UI から切り離した純粋なロジックとしてまとめる。
// 実際の CloudKit 通信はシミュレータで試せないため、判断部分だけをここに置いて単体テストする。
// 背景は docs/sharing.md を参照。

// MARK: - 状態遷移

extension ShareStatus {
    /// 状態の進み具合。依頼の状態は active → fired → completed と進み、cancelled はどこからでも行ける終点。
    /// 後戻りは無い（編集は active のときだけ許可している）。
    nonisolated var progressRank: Int {
        switch self {
        case .active:    return 0
        case .fired:     return 1
        case .completed: return 2
        case .cancelled: return 3
        }
    }

    /// 完了・取り消し済み。この状態の依頼には状態以外を書き込まない。
    nonisolated var isTerminal: Bool { self == .completed || self == .cancelled }

    /// サーバ上の状態が `current` のとき、`target` を書き込むべきか。
    ///
    /// 同じ状態や後戻りになる書き込みはしない。再送キューのリトライや、状態が変わった後の
    /// 余計な書き込みで、依頼者の購読通知（到着・完了）が何度も届くのを防ぐ。
    nonisolated static func shouldWrite(_ target: ShareStatus, over current: ShareStatus) -> Bool {
        target.progressRank > current.progressRank
    }

    /// 取得した状態 `incoming` で、手元の状態 `local` を置き換えてよいか。
    ///
    /// CKQuery は索引から結果を返すため、直後の取得では古い状態が返ることがある。
    /// 後戻りを受け入れると、手元で付けた「取り消し」「完了」が一瞬 active に戻ってしまう。
    nonisolated static func shouldAccept(_ incoming: ShareStatus, over local: ShareStatus) -> Bool {
        incoming.progressRank >= local.progressRank
    }
}

// MARK: - 依頼の本文を端末に残すか

/// 依頼の本文（`SharedMemoNoteStore`）を、依頼が終わった後まで端末に残さないための決まり。
enum SharedMemoNotePolicy {
    /// 受け取った依頼が完了した後も本文を残す時間。「到着で自動完了」の依頼は到着と同時に完了になるため、
    /// 到着してから本文を読めるよう少しだけ残す。
    nonisolated static let completedRetention: TimeInterval = 24 * 60 * 60

    /// 受け取った依頼（受信側）の本文を残すか。
    /// 監視中・到着済みは残す。取り消しは消す。完了は完了から `completedRetention` の間だけ残す。
    nonisolated static func retainsReceivedNote(status: ShareStatus, completedAt: Date?, now: Date) -> Bool {
        switch status {
        case .active, .fired:
            return true
        case .cancelled:
            return false
        case .completed:
            guard let completedAt else { return false }
            return now.timeIntervalSince(completedAt) < completedRetention
        }
    }
}

// MARK: - 共有の参加者から受信者を決める（依頼者側）

/// `CKShare.Participant` から必要な値だけを抜き出したもの（テストで組み立てられるよう値型にする）。
struct ShareParticipantSummary: Equatable, Sendable {
    var userRecordName: String
    var displayName: String
    var isOwner: Bool
    var isAccepted: Bool

    nonisolated init(userRecordName: String, displayName: String, isOwner: Bool, isAccepted: Bool) {
        self.userRecordName = userRecordName
        self.displayName = displayName
        self.isOwner = isOwner
        self.isAccepted = isAccepted
    }

    nonisolated init(_ participant: CKShare.Participant) {
        let name = participant.userIdentity.nameComponents.map {
            PersonNameComponentsFormatter().string(from: $0)
        } ?? ""
        self.init(
            userRecordName: participant.userIdentity.userRecordID?.recordName ?? "",
            displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            isOwner: participant.role == .owner,
            isAccepted: participant.acceptanceStatus == .accepted
        )
    }
}

/// CloudKit が保証する「共有を受諾した参加者」から確定した受信者。
struct VerifiedRecipient: Equatable, Sendable {
    var userRecordName: String
    /// 表示名。分からなければ空文字。
    var displayName: String
}

enum SharedMemoRecipientResolver {
    /// 共有の参加者一覧から、依頼の受信者を決める。
    ///
    /// - 受信者は「受諾済み・所有者以外・userRecordID が分かる」参加者に限る。レコードの
    ///   `recipientRecordID` / `recipientName` は参加者が自由に書けるため、本人確認には使わない。
    /// - 該当者が複数いる場合（旧版の公開リンクで複数人が参加した等）は、レコードで名乗っている人
    ///   （`claimedRecordName`）が参加者にいればその人、いなければ userRecordID の昇順で先頭の人。
    /// - 表示名は CloudKit の名前（連絡先・iCloud）を優先し、無ければ、その参加者本人が
    ///   レコードに書いた名前（`claimedName`）を使う。他人が書いた名前は使わない。
    nonisolated static func resolve(
        participants: [ShareParticipantSummary],
        claimedRecordName: String,
        claimedName: String
    ) -> VerifiedRecipient? {
        let candidates = participants
            .filter { !$0.isOwner && $0.isAccepted && !$0.userRecordName.isEmpty }
            .sorted { $0.userRecordName < $1.userRecordName }
        guard let chosen = candidates.first(where: { $0.userRecordName == claimedRecordName }) ?? candidates.first
        else { return nil }
        let claimed = claimedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = !chosen.displayName.isEmpty
            ? chosen.displayName
            : (chosen.userRecordName == claimedRecordName ? claimed : "")
        return VerifiedRecipient(userRecordName: chosen.userRecordName, displayName: name)
    }
}

// MARK: - リンクの送り直し

/// 送った依頼のリンクをどう送り直すか。
enum ShareResendMethod: Equatable {
    /// 旧版で作った公開リンクの共有。権限は変えず（参加済みの相手が切れるため）、同じ URL を送る。
    case legacyPublicURL(URL)
    /// 招待済みの相手がいる非公開の共有。URL は招待済みの相手しか開けないので、そのまま送る。
    case invitedURL(URL)
    /// 招待済みの相手がいない非公開の共有。システムの共有シートで相手を招待し直す。
    case systemInvite

    /// - Parameters:
    ///   - isPublic: `publicPermission != .none`
    ///   - hasInvitedParticipant: 所有者以外で、取り除かれていない参加者がいるか
    nonisolated static func decide(url: URL?, isPublic: Bool, hasInvitedParticipant: Bool) -> ShareResendMethod {
        guard let url else { return .systemInvite }
        if isPublic { return .legacyPublicURL(url) }
        return hasInvitedParticipant ? .invitedURL(url) : .systemInvite
    }
}

// MARK: - 削除したフレンドの記録

/// ユーザーが削除したフレンドの userRecordID を覚えておき、自動登録で復活させないための記録。
///
/// 依頼者側は「相手が依頼を受け取った」ことを同期のたびに確認してフレンドを自動登録する。
/// 記録が無いと、削除したフレンドが次の同期で戻ってしまう。
/// 端末ごとの App Group UserDefaults に置く（iCloud 間では同期しない。docs/sharing.md の制限事項を参照）。
struct FriendTombstoneStore {
    private static let key = "deletedFriendRecordIDs"
    let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    static var shared: FriendTombstoneStore {
        FriendTombstoneStore(defaults: UserDefaults(suiteName: GeoMemoStore.appGroupID))
    }

    var all: Set<String> {
        Set(defaults?.stringArray(forKey: Self.key) ?? [])
    }

    func contains(_ recordName: String) -> Bool {
        !recordName.isEmpty && all.contains(recordName)
    }

    func add(_ recordName: String) {
        guard !recordName.isEmpty, let defaults else { return }
        var current = all
        guard current.insert(recordName).inserted else { return }
        defaults.set(current.sorted(), forKey: Self.key)
    }

    func remove(_ recordName: String) {
        guard let defaults else { return }
        var current = all
        guard current.remove(recordName) != nil else { return }
        defaults.set(current.sorted(), forKey: Self.key)
    }
}

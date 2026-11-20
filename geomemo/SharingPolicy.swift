import Foundation
import CloudKit

// 依頼の共有（CKShare）まわりの判断を、CloudKit や UI から切り離した純粋なロジックとしてまとめる。
// 実際の CloudKit 通信はシミュレータで試せないため、判断部分だけをここに置いて単体テストする。
// 背景は docs/sharing.md を参照。

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
    /// 招待済みでまだ受諾していない（`.pending`、または状態不明の `.unknown`）。取り除かれた参加者は false。
    var isInvited: Bool

    nonisolated init(userRecordName: String, displayName: String, isOwner: Bool, isAccepted: Bool,
                     isInvited: Bool = false) {
        self.userRecordName = userRecordName
        self.displayName = displayName
        self.isOwner = isOwner
        self.isAccepted = isAccepted
        self.isInvited = isInvited
    }

    nonisolated init(_ participant: CKShare.Participant) {
        let name = participant.userIdentity.nameComponents.map {
            PersonNameComponentsFormatter().string(from: $0)
        } ?? ""
        self.init(
            userRecordName: participant.userIdentity.userRecordID?.recordName ?? "",
            displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            isOwner: participant.role == .owner,
            isAccepted: participant.acceptanceStatus == .accepted,
            isInvited: participant.acceptanceStatus == .pending || participant.acceptanceStatus == .unknown
        )
    }
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
        if !chosen.displayName.isEmpty {
            return VerifiedRecipient(userRecordName: chosen.userRecordName, displayName: chosen.displayName,
                                     nameIsFromCloudKit: true)
        }
        let claimed = claimedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = chosen.userRecordName == claimedRecordName ? claimed : ""
        return VerifiedRecipient(userRecordName: chosen.userRecordName, displayName: name)
    }
}

/// 送った依頼ごとに、共有の参加者から決めた受信者と、その共有の種類。
nonisolated struct ResolvedShareRecipient: Equatable, Sendable {
    var recipient: VerifiedRecipient
    /// 旧版で作った公開リンクの共有（`publicPermission != .none`）。URL を知っていれば誰でも参加でき、
    /// 受信者の選び方（`claimedRecordName` を優先）も参加者に操作されうるので、表示にだけ使う。
    var isPublicShare: Bool
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

// MARK: - フレンドの自動登録（依頼者側）

nonisolated enum FriendAutoRegistration: Equatable, Sendable {
    /// 登録しない
    case skip
    /// 登録する（既に登録済みなら何もしない）
    case register
    /// 削除の記録を外してから登録する（削除した後に、依頼者が自分で招待し直した相手）
    case registerClearingTombstone
}

nonisolated enum FriendAutoRegistrationPolicy {
    /// 依頼者側で、共有の参加者から受信者が決まったときに、その人をフレンドに登録するか。
    ///
    /// - 旧版の公開リンクの共有では登録しない（誰でも参加でき、受信者の選び方も参加者に操作されうる）。
    /// - 新しく受信者が決まったとき（招待で送った依頼を誰かが受け取った）だけ登録する。
    /// - 削除したフレンドは登録しない。ただし、削除した後に依頼者が招待で送った依頼
    ///   （`requestSentAt` は端末で記録した送信日時。相手が書けるレコードの値は使わない）を受け取ったなら、
    ///   依頼者自身の操作による招待なので、削除の記録を外して登録し直す（受信側の共有の受諾と同じ考え方）。
    nonisolated static func decide(
        isPublicShare: Bool,
        isNewRecipient: Bool,
        requestSentAt: Date,
        tombstonedAt: Date?
    ) -> FriendAutoRegistration {
        guard !isPublicShare, isNewRecipient else { return .skip }
        guard let tombstonedAt else { return .register }
        return requestSentAt > tombstonedAt ? .registerClearingTombstone : .skip
    }
}

// MARK: - 共有シートの結果

/// 依頼を送る共有シート（`UIActivityViewController`）の結果。
nonisolated enum ShareSheetOutcome: Equatable, Sendable {
    /// 送信（コピー等を含む）が完了した
    case sent
    /// 何も送らずに共有シートを閉じた（システムが「何も完了していない」と知らせた）
    case notSent
    /// 共有シートは閉じたが、送れたかどうか分からない
    case unknown
}

/// `completionWithItemsHandler` の呼び出しと共有シートが閉じたことから、送ったかどうかを決める。
///
/// iOS 13 以降、共有シートで「メッセージ」「メール」等を選んで作成画面をキャンセルすると、共有シートは
/// 開いたまま `completed == false`（`activityType` は選んだもの）で呼ばれる。ユーザーはそのまま別の方法で
/// 送れるので、この時点では決めない。
///
/// - `completed == true` → 送った。
/// - `activityType == nil && completed == false` → 何も送らずに閉じた。
/// - `activityType != nil && completed == false` → 次の呼び出しを待つ。
/// - 共有シートが閉じたのに結果が決まらない → 分からない（サーバのレコードは消さずに「未送信」として残す）。
///   その後に `completed == true` が届いたら「送った」に改める。
nonisolated struct ShareSheetCompletionTracker {
    private(set) var reported: ShareSheetOutcome?

    nonisolated init() {}

    /// 完了ハンドラの 1 回分を記録する。新しく知らせるべき結果があれば返す。
    nonisolated mutating func record(activityType: String?, completed: Bool) -> ShareSheetOutcome? {
        if completed {
            guard reported == nil || reported == .unknown else { return nil }
            reported = .sent
            return .sent
        }
        guard activityType == nil, reported == nil else { return nil }
        reported = .notSent
        return .notSent
    }

    /// 共有シートが閉じた後、しばらく待っても結果が決まらなかったときに呼ぶ。
    nonisolated mutating func sheetDismissedWithoutResult() -> ShareSheetOutcome? {
        guard reported == nil else { return nil }
        reported = .unknown
        return .unknown
    }
}

// MARK: - 送らなかった依頼の後片付け

/// 共有シートで送るために作った依頼のうち、まだ行き先の決まっていないものの記録。
nonisolated struct UnsentShareEntry: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// 共有シートを表示中（結果を待っている）。アプリが終了されるとこのまま残る。
        case presenting
        /// 送らずに閉じた。サーバのレコードと共有を消す（失敗したら次回の起動で再試行する）。
        case discarding
        /// 送れたか分からない。サーバに残し、見守り画面に「未送信」として出す（送り直すか削除はユーザーが決める）。
        case kept
    }

    var recordName: String
    var shareRecordName: String
    /// フレンドに送るとき参加者として加えた相手。新しい相手（招待）なら空。
    var invitedFriendRecordName: String
    /// 端末で記録した作成日時
    var createdAt: Date
    var state: State

    nonisolated init(recordName: String, shareRecordName: String, invitedFriendRecordName: String,
                     createdAt: Date, state: State) {
        self.recordName = recordName
        self.shareRecordName = shareRecordName
        self.invitedFriendRecordName = invitedFriendRecordName
        self.createdAt = createdAt
        self.state = state
    }
}

/// `UnsentShareEntry` を App Group の UserDefaults に置く（端末ごと）。
struct UnsentShareStore {
    private static let key = "unsentShares"
    let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    static var shared: UnsentShareStore {
        UnsentShareStore(defaults: UserDefaults(suiteName: GeoMemoStoreConfig.appGroupID))
    }

    var entries: [UnsentShareEntry] {
        guard let data = defaults?.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([UnsentShareEntry].self, from: data)
        else { return [] }
        return decoded
    }

    /// 「未送信」として残している依頼のレコード名
    var keptRecordNames: Set<String> {
        Set(entries.filter { $0.state == .kept }.map(\.recordName))
    }

    func entry(for recordName: String) -> UnsentShareEntry? {
        entries.first { $0.recordName == recordName }
    }

    func upsert(_ entry: UnsentShareEntry) {
        var current = entries.filter { $0.recordName != entry.recordName }
        current.append(entry)
        save(current)
    }

    func setState(_ state: UnsentShareEntry.State, for recordName: String) {
        var current = entries
        guard let index = current.firstIndex(where: { $0.recordName == recordName }),
              current[index].state != state
        else { return }
        current[index].state = state
        save(current)
    }

    func remove(_ recordName: String) {
        let current = entries
        let remaining = current.filter { $0.recordName != recordName }
        guard remaining.count != current.count else { return }
        save(remaining)
    }

    private func save(_ entries: [UnsentShareEntry]) {
        defaults?.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }
}

nonisolated enum UnsentShareCleanupPolicy {
    /// 共有シートの表示中にアプリが終了されたとみなすまでの時間
    nonisolated static let orphanAge: TimeInterval = 10 * 60

    enum Action: Equatable, Sendable {
        /// 何もしない（ユーザーが決める、またはまだ待つ）
        case leave
        /// サーバのレコードと共有を消す。`allowedInviteeRecordName` は、招待中のままでも消してよい参加者
        /// （フレンドに送るとき自分で加え、URL を送っていない相手）。
        case delete(allowedInviteeRecordName: String?)
    }

    /// 起動時の後片付けで、記録 1 件をどうするか。
    nonisolated static func action(for entry: UnsentShareEntry, now: Date) -> Action {
        switch entry.state {
        case .kept:
            return .leave
        case .discarding:
            // 送らずに閉じたことが分かっている。フレンドに URL は渡っていない
            return .delete(allowedInviteeRecordName: entry.invitedFriendRecordName.isEmpty
                           ? nil : entry.invitedFriendRecordName)
        case .presenting:
            // 結果が分からないまま残った。送った可能性があるので、参加者が誰もいないときだけ消す
            guard now.timeIntervalSince(entry.createdAt) >= orphanAge else { return .leave }
            return .delete(allowedInviteeRecordName: nil)
        }
    }

    /// 共有を消してよいか。所有者以外に、受諾した人・招待中の人がいれば消さない
    /// （相手に届いているかもしれないリンクを無効にしない）。
    /// `allowedInviteeRecordName` に一致する招待中（未受諾）の参加者だけは例外にできる。
    nonisolated static func canDelete(participants: [ShareParticipantSummary],
                                      allowedInviteeRecordName: String?) -> Bool {
        for participant in participants where !participant.isOwner {
            if participant.isAccepted { return false }
            if participant.isInvited {
                guard let allowed = allowedInviteeRecordName, !allowed.isEmpty,
                      participant.userRecordName == allowed
                else { return false }
            }
        }
        return true
    }
}

// MARK: - 送信後の編集で本文を書き込むか

nonisolated enum SharedMemoNoteEditPolicy {
    /// 編集画面の本文をどこから読んだか
    enum Source: Equatable, Sendable {
        /// サーバから読めた
        case server
        /// サーバから読めず、端末のキャッシュを出した（サーバにはもっと新しい本文があるかもしれない）
        case cache
        /// どちらからも読めなかった
        case unavailable
    }

    /// 保存するときに書き込む本文。nil なら本文には触れない。
    /// キャッシュから出した本文は、ユーザーが書き換えたときだけ書き込む（古い本文でサーバを上書きしない）。
    nonisolated static func noteToSave(source: Source, loaded: String, current: String) -> String? {
        switch source {
        case .server:      return current
        case .cache:       return current == loaded ? nil : current
        case .unavailable: return nil
        }
    }
}

// MARK: - 受信した依頼の取り込み（受信者側）

nonisolated enum SharedImportPolicy {
    /// 受信した依頼に、自分を受信者として書き込む（claim する）か。
    ///
    /// 取り込み自体はプロフィール（表示名）の有無に関係なく行う。名前を設定していない人は claim だけを
    /// 見送る。依頼者の側は、受信者を共有の参加者（CKShare.participants）から決めるので、名前が書き込まれなくても
    /// 受け取った人を認識できる（表示名は CloudKit の名前、無ければ「相手」）。
    /// プロフィールを後で設定すると、次の同期で（監視中の依頼に限り）書き込まれる。
    nonisolated static func shouldClaim(
        recipientRecordID: String,
        status: ShareStatus,
        myICloudRecordID: String?
    ) -> Bool {
        guard let myICloudRecordID, !myICloudRecordID.isEmpty else { return false }
        return recipientRecordID.isEmpty && status == .active
    }
}

// MARK: - 監視の登録順

nonisolated enum GeofenceRegistrationOrder {
    enum Entry<Received, Own> {
        case received(Received)
        case own(Own)
    }

    /// iOS の監視は 20 件までで、`LocationManager.startMonitoring` は上限に達すると黙って登録しない。
    /// 受信した依頼は、場所に着いたことが依頼者に伝わらなくなると相手の用が果たせないので、先に登録する。
    /// 溢れるのは自分のメモの後ろ（それぞれの並びは入力のまま）。
    nonisolated static func prioritized<Received, Own>(
        received: [Received], own: [Own]
    ) -> [Entry<Received, Own>] {
        received.map { .received($0) } + own.map { .own($0) }
    }
}

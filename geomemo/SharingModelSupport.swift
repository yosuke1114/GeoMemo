import Foundation

// SwiftData のモデル（SharedMemo / FriendConnection）が直接使う型だけをここに置く。
// Watch ターゲットもモデルを持つため、このファイルだけを共有し、依頼まわりの判断ロジック
// （SharingPolicy.swift、iPhone 専用）は Watch に入れない。

/// CloudKit が保証する「共有を受諾した参加者」から確定した受信者。
nonisolated struct VerifiedRecipient: Equatable, Sendable {
    var userRecordName: String
    /// 表示名。分からなければ空文字。
    var displayName: String
    /// 表示名が CloudKit の名前（連絡先・iCloud）か。false なら本人がレコードに書いた名前（または空）。
    var nameIsFromCloudKit: Bool = false
}


// MARK: - 削除したフレンドの記録

/// ユーザーが削除したフレンドの userRecordID と削除した日時を覚えておき、自動登録で復活させないための記録。
///
/// 依頼者側は「相手が依頼を受け取った」ことを同期のたびに確認してフレンドを自動登録する。
/// 記録が無いと、削除したフレンドが次の同期で戻ってしまう。
/// 端末ごとの App Group UserDefaults に置く（iCloud 間では同期しない。docs/sharing.md の制限事項を参照）。
struct FriendTombstoneStore {
    /// userRecordID → 削除した日時
    private static let key = "deletedFriends"
    /// 日時を持たない以前の形式（userRecordID の配列）。読んだら新しい形式へ移す。
    private static let legacyKey = "deletedFriendRecordIDs"
    let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    static var shared: FriendTombstoneStore {
        FriendTombstoneStore(defaults: UserDefaults(suiteName: GeoMemoStoreConfig.appGroupID))
    }

    private func load() -> [String: Date] {
        guard let defaults else { return [:] }
        var map = defaults.dictionary(forKey: Self.key) as? [String: Date] ?? [:]
        if let legacy = defaults.stringArray(forKey: Self.legacyKey) {
            // 削除した日時が分からないので、移行した時点で削除したものとして扱う（その後に送った依頼だけが記録を外せる）
            let now = Date()
            for recordName in legacy where !recordName.isEmpty && map[recordName] == nil {
                map[recordName] = now
            }
            defaults.set(map, forKey: Self.key)
            defaults.removeObject(forKey: Self.legacyKey)
        }
        return map
    }

    var all: Set<String> {
        Set(load().keys)
    }

    func contains(_ recordName: String) -> Bool {
        deletedAt(recordName) != nil
    }

    /// 削除した日時。削除の記録が無ければ nil。
    func deletedAt(_ recordName: String) -> Date? {
        guard !recordName.isEmpty else { return nil }
        return load()[recordName]
    }

    func add(_ recordName: String, at date: Date = Date()) {
        guard !recordName.isEmpty, let defaults else { return }
        var current = load()
        guard current[recordName] == nil else { return }
        current[recordName] = date
        defaults.set(current, forKey: Self.key)
    }

    func remove(_ recordName: String) {
        guard let defaults else { return }
        var current = load()
        guard current.removeValue(forKey: recordName) != nil else { return }
        defaults.set(current, forKey: Self.key)
    }
}


// MARK: - 本人確認できたフレンド

/// CloudKit の情報（共有の所有者・参加者）で本人と名前を確かめたフレンドの userRecordID。
///
/// 旧版は、共有の参加者が自由に書けるレコードのフィールド（受信者名・ID）からフレンドを登録していた。
/// そのため「母」という名前で別人の ID を持つフレンドが作られている可能性がある。非公開の共有では
/// フレンドを選ぶとその ID の人だけを招待するので、確かめていないフレンドには「未確認」と表示し、
/// 送る前に確認する。SwiftData のスキーマを変えないよう、App Group の UserDefaults に置く（端末ごと）。
struct VerifiedFriendStore {
    private static let key = "verifiedFriendRecordIDs"
    let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    static var shared: VerifiedFriendStore {
        VerifiedFriendStore(defaults: UserDefaults(suiteName: GeoMemoStoreConfig.appGroupID))
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
}

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
    /// サーバの状態が終点（完了・取り消し）なら何も書かない。オフラインで溜まった「取り消し」が、
    /// その後に相手が付けた「完了」を上書きしないようにする（終点の後は誰が書いても変わらない）。
    nonisolated static func shouldWrite(_ target: ShareStatus, over current: ShareStatus) -> Bool {
        guard !current.isTerminal else { return false }
        return target.progressRank > current.progressRank
    }

    /// 取得した状態 `incoming` で、手元の状態 `local` を置き換えてよいか。
    ///
    /// CKQuery は索引から結果を返すため、直後の取得では古い状態が返ることがある。
    /// 後戻りを受け入れると、手元で付けた「取り消し」「完了」が一瞬 active に戻ってしまう。
    nonisolated static func shouldAccept(_ incoming: ShareStatus, over local: ShareStatus) -> Bool {
        incoming.progressRank >= local.progressRank
    }
}

import Foundation
import CloudKit

// 依頼を受け取った人向けの画面（受け取り画面・バッジ・簡易表示）の表示判断に使う純粋なロジック（テスト対象）。
// 画面・SwiftData・CloudKit の通信には依存しない。すべて nonisolated にして、SwiftUI の描画スレッドや
// CloudKit の内部キューから呼ばれても Swift 6 の実行時の隔離検査で落ちないようにする。

// MARK: - 地図の下部に何を出すか

nonisolated enum HomeMode: Equatable {
    case standard
    /// 自分のメモも送った依頼も無く、受け取った依頼だけがある人。
    case receiverOnly

    nonisolated static func resolve(ownMemoCount: Int, sentRequestCount: Int, receivedRequestCount: Int) -> HomeMode {
        ownMemoCount == 0 && sentRequestCount == 0 && receivedRequestCount > 0 ? .receiverOnly : .standard
    }
}

// MARK: - 受け取った依頼 1 件の要約

/// 受け取った依頼（`SharedMemo`）から判断に要る値だけを抜き出したもの（テストで組み立てられるよう値型にする）。
nonisolated struct ReceivedSummary: Equatable, Sendable {
    var recordName: String
    /// 共有ゾーンの所有者名（= 依頼者の userRecordID）。
    var zoneOwner: String
    var status: ShareStatus
    var deadline: Date?
    var createdAt: Date
    var completedAt: Date?

    nonisolated init(recordName: String, zoneOwner: String = "", status: ShareStatus,
                     deadline: Date? = nil, createdAt: Date = Date(timeIntervalSince1970: 0),
                     completedAt: Date? = nil) {
        self.recordName = recordName
        self.zoneOwner = zoneOwner
        self.status = status
        self.deadline = deadline
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    nonisolated var isWaiting: Bool { status == .active }
    nonisolated var hasArrived: Bool { status == .fired }
}

// MARK: - 地図上部のバッジ

nonisolated enum ReceivedBadgeState: Equatable {
    case hidden
    case visible(count: Int, hasArrived: Bool, hasUnseen: Bool)

    /// 到着待ち・到着済みが 1 件以上あるときだけ出す。
    nonisolated static func resolve(waiting: Int, arrived: Int, unseen: Int) -> ReceivedBadgeState {
        let count = waiting + arrived
        guard count > 0 else { return .hidden }
        return .visible(count: count, hasArrived: arrived > 0, hasUnseen: unseen > 0)
    }

    nonisolated static func resolve(_ items: [ReceivedSummary], seen: Set<String>) -> ReceivedBadgeState {
        let open = items.filter { $0.isWaiting || $0.hasArrived }
        return resolve(waiting: open.filter(\.isWaiting).count,
                       arrived: open.filter(\.hasArrived).count,
                       unseen: open.filter { !seen.contains($0.recordName) }.count)
    }
}

// MARK: - 「受信した依頼」の一覧の節

nonisolated struct ReceivedRequestSections: Equatable {
    /// 到着済み（完了待ち）。
    var arrived: [String] = []
    /// 到着待ち。
    var waiting: [String] = []
    /// 最近終わった依頼（完了から `SharedMemoNotePolicy.completedRetention` 以内）。
    var recent: [String] = []

    nonisolated var isEmpty: Bool { arrived.isEmpty && waiting.isEmpty && recent.isEmpty }
    nonisolated var count: Int { arrived.count + waiting.count + recent.count }

    /// 各節の中は、期限の近い順（期限なしは後ろ）、同じなら受け取った順（新しい方が先）。
    nonisolated static func resolve(_ items: [ReceivedSummary], now: Date) -> ReceivedRequestSections {
        func ordered(_ list: [ReceivedSummary]) -> [String] {
            list.sorted { lhs, rhs in
                switch (lhs.deadline, rhs.deadline) {
                case let (l?, r?) where l != r: return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.createdAt > rhs.createdAt
                }
            }.map(\.recordName)
        }
        let recent = items.filter {
            guard $0.status == .completed, let completedAt = $0.completedAt else { return false }
            let elapsed = now.timeIntervalSince(completedAt)
            return elapsed >= 0 && elapsed < SharedMemoNotePolicy.completedRetention
        }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }.map(\.recordName)
        return ReceivedRequestSections(
            arrived: ordered(items.filter(\.hasArrived)),
            waiting: ordered(items.filter(\.isWaiting)),
            recent: recent)
    }
}

// MARK: - 期限の表示

nonisolated enum RequestDeadline {
    /// 期限を過ぎているか（期限ちょうどは過ぎていない）。表示だけに使い、到着の発火の条件には使わない。
    nonisolated static func isOverdue(_ deadline: Date?, now: Date) -> Bool {
        guard let deadline else { return false }
        return now > deadline
    }
}

// MARK: - 簡易表示のカードに出す 1 件

nonisolated enum ReceivedHighlight {
    /// 到着済みが先、次に期限の近い順（期限なしは後）、最後に受け取った順（新しい方が先）。
    /// 到着待ち・到着済みが無ければ nil。
    nonisolated static func pick(_ items: [ReceivedSummary]) -> String? {
        let open = items.filter { $0.isWaiting || $0.hasArrived }
        let sections = ReceivedRequestSections.resolve(open, now: Date())
        return sections.arrived.first ?? sections.waiting.first
    }
}

// MARK: - 受諾した共有に対して何を出すか

nonisolated struct AcceptedShareKey: Equatable, Sendable {
    /// `CKShare.Metadata.hierarchicalRootRecordID` のレコード名。取れなかったときは nil。
    var rootRecordName: String?
    /// 共有の所有者（依頼者）の userRecordID。
    var ownerRecordID: String

    nonisolated init(rootRecordName: String?, ownerRecordID: String) {
        self.rootRecordName = rootRecordName
        self.ownerRecordID = ownerRecordID
    }
}

nonisolated enum ArrivalPresentation: Equatable, Identifiable {
    /// 新しく取り込んだ → 受け取り画面。
    case arrival(recordName: String)
    /// 既に取り込み済み（リンクを 2 回開いた）→ 通常の詳細。
    case existing(recordName: String)
    /// 複数まとめて → 一覧。
    case list(recordNames: [String])
    /// 取り消し済みで取り込まなかった → 知らせるだけ。
    case cancelledBeforeOpen

    nonisolated var id: String {
        switch self {
        case .arrival(let name): return "arrival.\(name)"
        case .existing(let name): return "existing.\(name)"
        case .list(let names): return "list.\(names.joined(separator: ","))"
        case .cancelledBeforeOpen: return "cancelled"
        }
    }
}

nonisolated enum ArrivalResolver {
    /// 1 つの鍵に対応する依頼（取り込み済みのレコード名）と、取り消し済みで取り込まなかった依頼があったか。
    private nonisolated static func match(
        _ key: AcceptedShareKey,
        received: [ReceivedSummary],
        newlyInserted: Set<String>,
        skippedCancelled: [String: String],
        freshCancelled: Set<String>
    ) -> (names: [String], cancelled: Bool) {
        if let root = key.rootRecordName, !root.isEmpty {
            if received.contains(where: { $0.recordName == root }) { return ([root], false) }
            return ([], skippedCancelled[root] != nil)
        }
        // ルートのレコード名が取れなかったときの保険。取り消しは、受諾の後に初めて見つけたものだけを対象にする
        // （前から残っている同じ依頼者の取り消し済みの依頼を、今回の受諾と取り違えない）。
        let byOwner = received.filter { newlyInserted.contains($0.recordName) && $0.zoneOwner == key.ownerRecordID }.map(\.recordName)
        if !byOwner.isEmpty { return (byOwner, false) }
        let cancelled = skippedCancelled.contains { freshCancelled.contains($0.key) && $0.value == key.ownerRecordID }
        return ([], cancelled)
    }

    /// 受諾した共有に対応する依頼を探し、何を出すか決める。見つからなければ nil（同期をやり直す）。
    ///
    /// - `rootRecordName` があればそのレコード名で探す。無ければ、新しく取り込んだ依頼のうち
    ///   ゾーンの所有者が `ownerRecordID` と同じものを使う（同じ依頼者から 2 件を同時に受諾すると区別できず一覧になる）。
    /// - `skippedCancelled` は、取り消し済みで取り込まなかった依頼（レコード名 → ゾーンの所有者）。
    /// - `freshCancelled` は、そのうち受諾より後に初めて見つけたもの（ルートが無いときの保険にだけ使う。nil なら全部）。
    nonisolated static func resolve(
        accepted: [AcceptedShareKey],
        received: [ReceivedSummary],
        newlyInserted: Set<String>,
        skippedCancelled: [String: String],
        freshCancelled: Set<String>? = nil
    ) -> ArrivalPresentation? {
        var found: [String] = []
        var cancelledFound = false
        let fresh = freshCancelled ?? Set(skippedCancelled.keys)
        for key in accepted {
            let m = match(key, received: received, newlyInserted: newlyInserted,
                          skippedCancelled: skippedCancelled, freshCancelled: fresh)
            for name in m.names where !found.contains(name) { found.append(name) }
            if m.cancelled { cancelledFound = true }
        }
        if found.count >= 2 { return .list(recordNames: found) }
        if let only = found.first {
            return newlyInserted.contains(only) ? .arrival(recordName: only) : .existing(recordName: only)
        }
        return cancelledFound ? .cancelledBeforeOpen : nil
    }

    /// 依頼が見つかった（または取り消し済みと分かった）鍵。残りは次の試行に回す。
    nonisolated static func resolvedKeys(
        accepted: [AcceptedShareKey],
        received: [ReceivedSummary],
        newlyInserted: Set<String>,
        skippedCancelled: [String: String],
        freshCancelled: Set<String>? = nil
    ) -> [AcceptedShareKey] {
        let fresh = freshCancelled ?? Set(skippedCancelled.keys)
        return accepted.filter {
            let m = match($0, received: received, newlyInserted: newlyInserted,
                          skippedCancelled: skippedCancelled, freshCancelled: fresh)
            return !m.names.isEmpty || m.cancelled
        }
    }
}

// MARK: - 受け取り画面に出す内容

nonisolated enum ReceivedArrivalNotice: Equatable {
    /// 位置情報が「使用中のみ」。依頼者への到着の連絡のための専用の文を出す。
    case whenInUseOnly
    /// そのほかの許可の不足（PR #11 の案内の文をそのまま出す）。
    case permission(PermissionNotice)
    /// 監視の上限を超えている（許可の不足が無いとき）。
    case monitoringLimit(MonitoringLimitState)
}

nonisolated struct ReceivedArrivalContent: Equatable {
    /// 足りない許可の案内（1 件。いちばん重要なもの）。監視中の依頼のときだけ。
    var notice: ReceivedArrivalNotice?
    /// 「この依頼について」の 3 項目を出すか（監視中の依頼のときだけ）。
    var showsAbout: Bool
    /// 「名前を伝える」の行を出すか（プロフィールが無く、監視中のとき）。
    var showsNamePrompt: Bool
    /// 「あなたの名前（○○）が表示されます」を出すか（プロフィールがあり、監視中のとき）。
    var showsYourName: Bool

    nonisolated static func resolve(
        status: ShareStatus,
        permissions: PermissionSnapshot,
        hasProfile: Bool,
        requiredRegions: Int
    ) -> ReceivedArrivalContent {
        // 到着済み・完了・取り消しの依頼には、これから到着が伝わる前提の説明・案内・名前の行は出さない
        guard status == .active else {
            return ReceivedArrivalContent(notice: nil, showsAbout: false, showsNamePrompt: false, showsYourName: false)
        }
        var notice: ReceivedArrivalNotice?
        if let top = PermissionNotice.resolve(permissions) {
            notice = top == .locationWhenInUseOnly ? .whenInUseOnly : .permission(top)
        } else {
            let limit = MonitoringLimitState.resolve(requiredRegions: requiredRegions)
            if case .overLimit = limit { notice = .monitoringLimit(limit) }
        }
        return ReceivedArrivalContent(notice: notice, showsAbout: true,
                                      showsNamePrompt: !hasProfile, showsYourName: hasProfile)
    }
}

// MARK: - 依頼者の名前

/// 見出しなどに出す依頼者の名前。レコードに依頼者が書いた名前は自己申告なので、
/// CloudKit の共有で確認できた名前（確認済みのフレンドの表示名）があればそれを優先し、食い違うときは両方出す。
nonisolated struct RequesterIdentity: Equatable {
    /// 見出し・通知に出す名前。空なら「依頼した人」などに置き換える。
    var displayName: String
    /// 確認済みの名前と、依頼者がレコードに書いた名前が食い違うときの、書かれた名前。
    var writtenName: String?

    nonisolated static func resolve(writtenName: String, verifiedName: String?) -> RequesterIdentity {
        let written = writtenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let verified = (verifiedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !verified.isEmpty else { return RequesterIdentity(displayName: written, writtenName: nil) }
        let differs = !written.isEmpty && written != verified
        return RequesterIdentity(displayName: verified, writtenName: differs ? written : nil)
    }
}

// MARK: - 断った依頼の記録

/// 「断る」で共有から抜けるのに失敗したとき、次の同期で依頼が復活（取り込み・監視の再開）しないよう、
/// 断ったレコード名（と、抜け直すための共有ゾーンの所有者）を端末に残す。同期のたびに抜け直しを再試行し、
/// 成功したら消す。同じ依頼を受諾し直したときも消す。App Group の UserDefaults に端末ごとに記録する。
nonisolated struct DeclinedRequestStore {
    private static let key = "declinedReceivedRequests"
    let defaults: UserDefaults?

    nonisolated init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    nonisolated static var shared: DeclinedRequestStore {
        DeclinedRequestStore(defaults: UserDefaults(suiteName: GeoMemoStore.appGroupID))
    }

    /// レコード名 → 共有ゾーンの所有者。
    nonisolated var entries: [String: String] {
        (defaults?.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
    }

    nonisolated func contains(_ recordName: String) -> Bool { entries[recordName] != nil }

    nonisolated func add(recordName: String, zoneOwner: String) {
        guard !recordName.isEmpty, let defaults else { return }
        var current = entries
        current[recordName] = zoneOwner
        defaults.set(current, forKey: Self.key)
    }

    nonisolated func remove(_ recordName: String) {
        guard let defaults else { return }
        var current = entries
        guard current.removeValue(forKey: recordName) != nil else { return }
        defaults.set(current, forKey: Self.key)
    }

    /// 同じ依頼を受諾し直したときに消す。ルートのレコード名が取れなかったときは、依頼者が同じものを消す。
    nonisolated func removeForReaccept(rootRecordName: String?, ownerRecordID: String) {
        if let root = rootRecordName, !root.isEmpty {
            remove(root)
        } else {
            for (name, owner) in entries where owner == ownerRecordID { remove(name) }
        }
    }
}

// MARK: - 受諾の失敗の分類

nonisolated enum ShareAcceptFailure: Equatable {
    case notSignedIn
    case network
    case goneOrCancelled
    case notInvited
    /// 招待された Apple ID でサインインしているか確かめてほしい（`.participantMayNeedVerification`）。
    case needsVerification
    case other

    /// CKError のコードから分類する。ここに挙げたもの以外（nil を含む）は汎用の `.other`。
    nonisolated static func classify(_ code: CKError.Code?) -> ShareAcceptFailure {
        switch code {
        case .notAuthenticated, .accountTemporarilyUnavailable: return .notSignedIn
        case .networkUnavailable, .networkFailure: return .network
        case .unknownItem, .zoneNotFound: return .goneOrCancelled
        case .permissionFailure: return .notInvited
        case .participantMayNeedVerification: return .needsVerification
        default: return .other
        }
    }

    /// 受諾の失敗（`CKAcceptSharesOperation` は `.partialFailure` で包んで返すことがある）から分類する。
    /// 包まれていれば中身のコードを見る。中身が複数あって食い違うときは汎用にする。
    nonisolated static func classify(error: Error) -> ShareAcceptFailure {
        guard let ckError = error as? CKError else { return .other }
        if ckError.code == .partialFailure, let inner = ckError.partialErrorsByItemID {
            let codes = Set(inner.values.compactMap { ($0 as? CKError)?.code.rawValue })
            if codes.count == 1, let raw = codes.first {
                return classify(CKError.Code(rawValue: raw))
            }
            return .other
        }
        return classify(ckError.code)
    }
}

// MARK: - 端末ごとの既読

/// 受け取り画面・一覧・詳細を開いた依頼のレコード名を、端末ごとに覚える（iCloud では同期しない）。
/// SwiftData のスキーマを変えないよう、App Group の UserDefaults に置く（`VerifiedFriendStore` と同じ形）。
nonisolated struct ReceivedRequestSeenStore {
    private static let seenKey = "receivedRequestSeen"
    private static let seededKey = "receivedRequestSeenSeeded"
    let defaults: UserDefaults?

    nonisolated init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    nonisolated static var shared: ReceivedRequestSeenStore {
        ReceivedRequestSeenStore(defaults: UserDefaults(suiteName: GeoMemoStore.appGroupID))
    }

    nonisolated var all: Set<String> {
        Set(defaults?.stringArray(forKey: Self.seenKey) ?? [])
    }

    nonisolated func isSeen(_ recordName: String) -> Bool { all.contains(recordName) }

    nonisolated func markSeen(_ recordName: String) {
        guard !recordName.isEmpty, let defaults else { return }
        var current = all
        guard current.insert(recordName).inserted else { return }
        defaults.set(current.sorted(), forKey: Self.seenKey)
    }

    /// この版の最初の起動で、その時点で端末にある依頼をすべて既読にする（1 回だけ）。
    /// これをしないと、アップデートした人のバッジに既存の依頼がすべて「新着」で出る。
    /// - Returns: 種をまいたら true。
    @discardableResult
    nonisolated func seedIfNeeded(existing: [String]) -> Bool {
        guard let defaults, !defaults.bool(forKey: Self.seededKey) else { return false }
        defaults.set(Set(existing).union(all).sorted(), forKey: Self.seenKey)
        defaults.set(true, forKey: Self.seededKey)
        return true
    }

    /// 今ある依頼に無いレコード名を捨てる（削除・取り消しで消えた依頼の分）。
    nonisolated func prune(keeping current: Set<String>) {
        guard let defaults else { return }
        let existing = all
        let kept = existing.intersection(current)
        if kept != existing { defaults.set(kept.sorted(), forKey: Self.seenKey) }
    }
}

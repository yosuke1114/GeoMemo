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
    /// 受諾した共有に対応する依頼を探し、何を出すか決める。見つからなければ nil（同期をやり直す）。
    ///
    /// - `rootRecordName` があればそのレコード名で探す。無ければ、新しく取り込んだ依頼のうち
    ///   ゾーンの所有者が `ownerRecordID` と同じものを使う（同じ依頼者から 2 件を同時に受諾すると区別できず一覧になる）。
    /// - `skippedCancelled` は、取り消し済みで取り込まなかった依頼（レコード名 → ゾーンの所有者）。
    nonisolated static func resolve(
        accepted: [AcceptedShareKey],
        received: [ReceivedSummary],
        newlyInserted: Set<String>,
        skippedCancelled: [String: String]
    ) -> ArrivalPresentation? {
        var found: [String] = []
        var cancelledFound = false
        func add(_ name: String) { if !found.contains(name) { found.append(name) } }

        for key in accepted {
            if let root = key.rootRecordName, !root.isEmpty {
                if received.contains(where: { $0.recordName == root }) {
                    add(root)
                } else if skippedCancelled[root] != nil {
                    cancelledFound = true
                }
            } else {
                let byOwner = received.filter { newlyInserted.contains($0.recordName) && $0.zoneOwner == key.ownerRecordID }
                byOwner.forEach { add($0.recordName) }
                if byOwner.isEmpty, skippedCancelled.values.contains(key.ownerRecordID) {
                    cancelledFound = true
                }
            }
        }

        if found.count >= 2 { return .list(recordNames: found) }
        if let only = found.first {
            return newlyInserted.contains(only) ? .arrival(recordName: only) : .existing(recordName: only)
        }
        return cancelledFound ? .cancelledBeforeOpen : nil
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
    /// 見出しに依頼者の名前を出すか（名前が空なら出さない）。
    var headingRequesterName: String?
    /// 足りない許可の案内（1 件。いちばん重要なもの）。
    var notice: ReceivedArrivalNotice?
    /// 「名前を伝える」の行を出すか（プロフィールが無いときだけ）。
    var showsNamePrompt: Bool

    nonisolated static func resolve(
        requesterName: String,
        permissions: PermissionSnapshot,
        hasProfile: Bool,
        requiredRegions: Int
    ) -> ReceivedArrivalContent {
        let trimmed = requesterName.trimmingCharacters(in: .whitespacesAndNewlines)
        var notice: ReceivedArrivalNotice?
        if let top = PermissionNotice.resolve(permissions) {
            notice = top == .locationWhenInUseOnly ? .whenInUseOnly : .permission(top)
        } else {
            let limit = MonitoringLimitState.resolve(requiredRegions: requiredRegions)
            if case .overLimit = limit { notice = .monitoringLimit(limit) }
        }
        return ReceivedArrivalContent(
            headingRequesterName: trimmed.isEmpty ? nil : trimmed,
            notice: notice,
            showsNamePrompt: !hasProfile)
    }
}

// MARK: - 受諾の失敗の分類

nonisolated enum ShareAcceptFailure: Equatable {
    case notSignedIn
    case network
    case goneOrCancelled
    case notInvited
    case other

    /// CKError のコードから分類する。ここに挙げたもの以外（nil を含む）は汎用の `.other`。
    nonisolated static func classify(_ code: CKError.Code?) -> ShareAcceptFailure {
        switch code {
        case .notAuthenticated: return .notSignedIn
        case .networkUnavailable, .networkFailure: return .network
        case .unknownItem, .zoneNotFound: return .goneOrCancelled
        case .permissionFailure, .participantMayNeedVerification: return .notInvited
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

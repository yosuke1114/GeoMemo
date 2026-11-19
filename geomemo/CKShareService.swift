import CloudKit
import Foundation
import os

/// Private DB + CKShare ベースの SharedMemo 管理サービス。
///
/// 設計方針（詳細は docs/sharing.md）:
/// - レコードは依頼者の Private DB のカスタムゾーン (`sharingZoneName`) に保存する。
/// - 共有は **非公開**（`publicPermission = .none`）で作り、受信者を参加者として明示的に加える。
///   共有 URL を開けるのは参加者だけで、URL が第三者に渡っても参加できない。
///   - フレンドに送る: 相手の userRecordID から参加者を引き、書き込み権限付きで加えてから URL を送る。
///   - 新しい相手に送る: システムの共有シート（`NSItemProvider.registerCKShare`、
///     `.specifiedRecipientsOnly`）で相手を選ぶと、システムがその人を参加者に加える。
/// - 旧版で作った共有は `publicPermission = .readWrite`（URL を知っていれば誰でも参加できる）のまま残す。
///   `.none` に変えると公開リンクから参加した受信者が CloudKit によって外されるため。
/// - `encryptedValues` は CloudKit 上での保存時暗号化で、**参加者には復号された値が見える**。
///   内容を守っているのは「参加者を限定していること」であって、暗号化ではない。
/// - 参加者は（書き込み権限の範囲で）レコードの全フィールドを書き換えられる。依頼者側は、
///   相手が書いた値を本人確認や通知文には使わない（受信者は `CKShare.participants` から決める）。
/// - SharedMemo SwiftData モデルはそのままローカルキャッシュとして使用する。
@MainActor
final class CKShareService {
    static let shared = CKShareService()

    let container = CKContainer(identifier: geomemoApp.cloudKitContainerID)
    var privateDB: CKDatabase { container.privateCloudDatabase }
    var sharedDB:  CKDatabase { container.sharedCloudDatabase  }

    nonisolated static let sharingZoneName = "geomemoSharingZone"
    nonisolated static let recordType      = "SharedMemo"  // 旧 SharedMemoRecord と区別

    /// 共有まわりのログ。ゾーン ID（＝相手の userRecordID）や座標などは `.private` で出す。
    nonisolated static let logger = Logger(subsystem: "com.yokuro.geomemo", category: "sharing")

    /// 新しい相手を招待するときにシステムの共有シートへ渡すオプション。
    /// 招待した人だけが参加でき（`.specifiedRecipientsOnly`）、参加者は書き込みでき（状態の更新に必要）、
    /// 参加者が他の人を招待することはできない。
    static var allowedSharingOptions: CKAllowedSharingOptions {
        let options = CKAllowedSharingOptions(
            allowedParticipantPermissionOptions: .readWrite,
            allowedParticipantAccessOptions: .specifiedRecipientsOnly
        )
        options.allowsParticipantsToInviteOthers = false
        options.allowsAccessRequests = false
        return options
    }

    private var zoneEnsured = false

    enum ServiceError: Error {
        /// 依頼が監視中 (active) でないため編集できない
        case notEditable
        /// 依頼に共有が付いていない
        case shareNotFound
    }

    // MARK: - Zone Bootstrap

    /// CKShare に必要なカスタムゾーンを Private DB に用意する（冪等）。
    func ensureSharingZone() async throws {
        if zoneEnsured { return }
        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        do {
            _ = try await privateDB.recordZone(for: zoneID)
            zoneEnsured = true
        } catch let error as CKError where error.code == .zoneNotFound {
            let zone = CKRecordZone(zoneID: zoneID)
            _ = try await privateDB.save(zone)
            zoneEnsured = true
        }
    }

    // MARK: - 依頼を作成（依頼者）

    struct PreparedShare {
        let record: CKRecord
        let share: CKShare
        /// フレンドを参加者として追加済み。true なら `share.url` を送ればよい（その相手しか参加できない）。
        /// false なら、システムの共有シートで相手を招待する必要がある。
        let invitedFriend: Bool
    }

    /// 新しい SharedMemo レコードと非公開の CKShare を作って保存する。
    ///
    /// - Parameter friendRecordName: フレンドに送る場合、その userRecordID。参加者として追加する。
    ///   参加者を引けなかった場合（相手の iCloud 状態など）は追加せずに作り、`invitedFriend == false`
    ///   を返す（呼び出し側はシステムの共有シートで招待する）。
    func createSharedMemoShare(
        from memo: GeoMemo,
        requesterName: String,
        friendRecordName: String?,
        friendName: String?,
        autoComplete: Bool
    ) async throws -> PreparedShare {
        try await ensureSharingZone()

        var friendParticipant: CKShare.Participant?
        if let friendRecordName, !friendRecordName.isEmpty {
            friendParticipant = await lookUpParticipant(userRecordName: friendRecordName)
        }

        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)

        // CloudKit 上では保存時に暗号化される（Dashboard 等では読めない）。参加者には復号されて見える。
        record.encryptedValues["memoTitle"]        = memo.title
        record.encryptedValues["memoNote"]         = memo.note
        record.encryptedValues["memoLocationName"] = memo.locationName
        record.encryptedValues["memoLatitude"]     = memo.latitude
        record.encryptedValues["memoLongitude"]    = memo.longitude

        record["memoRadius"]          = memo.radius
        record["memoDeadline"]        = memo.deadline
        record["memoTimeWindowStart"] = memo.timeWindowStart
        record["memoTimeWindowEnd"]   = memo.timeWindowEnd
        record["requesterName"]       = requesterName
        // 受信者が決まっているのはフレンドを参加者に加えられたときだけ。
        // それ以外は空にしておき、受け取った人が自分の名前を書き込む（claimRecipient）。
        record["recipientRecordID"]   = friendParticipant == nil ? "" : (friendRecordName ?? "")
        record["recipientName"]       = friendParticipant == nil ? "" : (friendName ?? "")
        record["autoComplete"]        = autoComplete ? 1 : 0
        record["status"]              = ShareStatus.active.rawValue
        record["createdAt"]           = Date()

        let share = CKShare(rootRecord: record)
        // リンクのプレビューやシステムの共有画面に出る題名。依頼の内容は出さない。
        share[CKShare.SystemFieldKey.title] = String(localized: "geomemo の依頼") as CKRecordValue
        // 非公開の共有。参加者として加えた人（またはシステムの共有シートで招待した人）しか参加できない。
        share.publicPermission = .none
        share.allowsAccessRequests = false
        if let friendParticipant {
            friendParticipant.permission = .readWrite
            friendParticipant.role = .privateUser
            share.addParticipant(friendParticipant)
        }

        // record と share をアトミックに保存：途中で失敗すると dangling record が残るのを防ぐ
        let (results, _) = try await privateDB.modifyRecords(
            saving: [record, share], deleting: []
        )
        var savedRecord = record
        var savedShare = share
        for (_, result) in results {
            switch try result.get() {
            case let saved as CKShare: savedShare = saved   // サーバ確定後の share (url 付き)
            case let saved: savedRecord = saved
            }
        }
        return PreparedShare(record: savedRecord, share: savedShare, invitedFriend: friendParticipant != nil)
    }

    /// userRecordID から共有の参加者を引く。引けなければ nil。
    private func lookUpParticipant(userRecordName: String) async -> CKShare.Participant? {
        let userRecordID = CKRecord.ID(recordName: userRecordName)
        do {
            let results = try await container.shareParticipants(forUserRecordIDs: [userRecordID])
            return try results[userRecordID]?.get()
        } catch {
            Self.logger.error("participant lookup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 送らずに閉じた依頼のレコードと共有をサーバから消す。
    func deleteUnsentShare(recordID: CKRecord.ID, shareID: CKRecord.ID?) async throws {
        // 共有のルートレコードを消すと共有も消えるが、念のため両方を指定する（片方が無くても続行）
        let ids = [shareID, recordID].compactMap { $0 }
        _ = try await privateDB.modifyRecords(saving: [], deleting: ids, atomically: false)
    }

    // MARK: - ステータス更新

    /// 依頼者・受信者どちらからでも呼べる（CKShare の writePermission 次第）。
    /// zoneID.ownerName から先に DB を確定し、`.unknownItem` の時だけもう一方へ
    /// フォールバックする。permission error など他のエラーは呼び出し元へ伝播。
    ///
    /// サーバの状態が既に同じか先へ進んでいれば書き込まない。再送キューのリトライや二重の発火で
    /// レコードが更新されると、依頼者の購読（到着・完了）が再び通知を出してしまうため。
    func updateStatus(recordID: CKRecord.ID, status: ShareStatus, date: Date? = nil) async throws {
        let isMyZone = recordID.zoneID.ownerName == CKCurrentUserDefaultName
        let primaryDB:  CKDatabase = isMyZone ? privateDB : sharedDB
        let fallbackDB: CKDatabase = isMyZone ? sharedDB  : privateDB

        let record: CKRecord
        do {
            record = try await primaryDB.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = try await fallbackDB.record(for: recordID)
        }
        let current = ShareStatus(rawValue: record["status"] as? String ?? "") ?? .active
        guard ShareStatus.shouldWrite(status, over: current) else { return }
        record["status"] = status.rawValue
        switch status {
        case .fired:     record["firedAt"]     = date
        case .completed: record["completedAt"] = date
        default: break
        }
        // 取得した CKRecord の zoneID から書き戻し先を決定する。
        let saveDB: CKDatabase = record.recordID.zoneID.ownerName == CKCurrentUserDefaultName
            ? privateDB : sharedDB
        _ = try await saveDB.save(record)
    }

    func cancelSharedMemo(recordID: CKRecord.ID) async throws {
        try await updateStatus(recordID: recordID, status: .cancelled)
    }

    // MARK: - 自分が送った SharedMemo を取得（依頼者）

    /// 自分の Private DB 内の SharedMemo レコードを取得する。
    func fetchSentSharedMemos() async throws -> [SharedMemoCKData] {
        try await ensureSharingZone()
        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let predicate = NSPredicate(format: "status != %@", ShareStatus.cancelled.rawValue)
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        return try await fetchAll(database: privateDB, query: query, zoneID: zoneID, isMyRequest: true)
    }

    /// 送った依頼ごとに、共有を受諾した受信者を CloudKit の参加者情報から決める。
    /// - Returns: レコード名 → 受信者。受諾した人がいない依頼は含まない。
    func fetchVerifiedRecipients(for sent: [SharedMemoCKData]) async throws -> [String: VerifiedRecipient] {
        let pairs = sent.compactMap { data in data.shareRecordID.map { (data, $0) } }
        guard !pairs.isEmpty else { return [:] }

        var shares: [CKRecord.ID: CKShare] = [:]
        let shareIDs = Array(Set(pairs.map(\.1)))
        for start in stride(from: 0, to: shareIDs.count, by: 200) {
            let chunk = Array(shareIDs[start..<min(start + 200, shareIDs.count)])
            let results = try await privateDB.records(for: chunk)
            for (id, result) in results {
                if case .success(let record) = result, let share = record as? CKShare {
                    shares[id] = share
                }
            }
        }

        var recipients: [String: VerifiedRecipient] = [:]
        for (data, shareID) in pairs {
            guard let share = shares[shareID] else { continue }
            let participants = share.participants.map(ShareParticipantSummary.init)
            if let recipient = SharedMemoRecipientResolver.resolve(
                participants: participants,
                claimedRecordName: data.recipientRecordID,
                claimedName: data.recipientName
            ) {
                recipients[data.ckRecordID.recordName] = recipient
            }
        }
        return recipients
    }

    // MARK: - 自分宛ての SharedMemo を取得（受信者）

    /// Shared DB から、自分が受諾済みの SharedMemo を取得する。
    /// 他人のゾーンは見えないので、まずゾーン一覧を取得して各ゾーンを並列に走査する。
    /// 1 ゾーンの認可剥奪 (`.zoneNotFound` 等) で全体が止まらないよう、
    /// 子タスクは個別 catch して失敗ゾーンを空配列で返す。
    func fetchReceivedSharedMemos() async throws -> [SharedMemoCKData] {
        let zones = try await sharedDB.allRecordZones()
        // 取り消し済み (cancelled) も取得する。除外すると依頼者の取り消しが受信側に伝わらず、
        // 受信側の依頼が active のまま残り、ジオフェンス監視も止まらない。
        // 条件は従来どおり status フィールドだけを使う（CloudKit の queryable インデックスを変えない）。
        let allStatuses = [ShareStatus.active, .fired, .completed, .cancelled].map(\.rawValue)
        return await withTaskGroup(of: [SharedMemoCKData].self) { group in
            for zone in zones {
                let zoneID = zone.zoneID
                group.addTask {
                    do {
                        // NSPredicate は Sendable でないため子タスク内で組み立てる
                        let predicate = NSPredicate(format: "status IN %@", allStatuses)
                        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
                        return try await self.fetchAll(database: self.sharedDB, query: query, zoneID: zoneID, isMyRequest: false)
                    } catch {
                        // 個別ゾーンの失敗は無視して継続。ゾーンの所有者は相手の ID なので private で出す。
                        Self.logger.error("zone \(zoneID.ownerName, privacy: .private) fetch failed: \(error.localizedDescription, privacy: .public)")
                        return []
                    }
                }
            }
            var all: [SharedMemoCKData] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
    }

    // MARK: - 送信後の編集・リンクの再送（依頼者）

    /// 送った依頼の現在の内容（本文を含む）をサーバから読む。編集画面を開くときに使う。
    func fetchSentSharedMemo(recordID: CKRecord.ID) async throws -> SharedMemoCKData? {
        let record = try await privateDB.record(for: recordID)
        return SharedMemoCKData(from: record, isMyRequest: true)
    }

    /// 依頼の内容（タイトル・本文・期限）を送信後に更新する。依頼者の Private DB にのみ書く。
    ///
    /// - 監視中 (active) の依頼だけを編集できる。到着・完了後にレコードを更新すると、
    ///   依頼者の購読が「到着」「完了」の通知を再び出してしまうため。
    /// - `note` が nil なら本文には触れない（本文を読み込めなかったときに空で上書きしない）。
    func updateSharedMemoContent(recordID: CKRecord.ID, title: String, note: String?, deadline: Date?) async throws {
        let record = try await privateDB.record(for: recordID)
        guard (record["status"] as? String) == ShareStatus.active.rawValue else {
            throw ServiceError.notEditable
        }
        record.encryptedValues["memoTitle"] = title
        if let note {
            record.encryptedValues["memoNote"] = note
        }
        record["memoDeadline"] = deadline
        _ = try await privateDB.save(record)
    }

    /// 依頼のリンクを送り直す方法を決める（リンクを失くした相手へ送り直す用）。
    /// 公開リンクには戻さない。旧版で作った公開リンクの共有だけは、そのままの URL を返す。
    func resendMethod(for recordID: CKRecord.ID) async throws -> (method: ShareResendMethod, share: CKShare) {
        let record = try await privateDB.record(for: recordID)
        guard let shareID = record.share?.recordID,
              let share = try await privateDB.record(for: shareID) as? CKShare
        else { throw ServiceError.shareNotFound }
        let hasInvitedParticipant = share.participants.contains {
            $0.role != .owner && ($0.acceptanceStatus == .pending || $0.acceptanceStatus == .accepted)
        }
        let method = ShareResendMethod.decide(
            url: share.url,
            isPublic: share.publicPermission != .none,
            hasInvitedParticipant: hasInvitedParticipant
        )
        return (method, share)
    }

    // MARK: - 依頼者への通知（CloudKit の購読）

    nonisolated static let arrivedSubscriptionID   = "requester-arrived-v2"
    nonisolated static let completedSubscriptionID = "requester-completed-v2"
    /// 通知文に受信者名（相手が書けるフィールド）を差し込んでいた旧版の購読。見つけたら消す。
    nonisolated static let legacySubscriptionIDs   = ["requester-arrived-v1", "requester-completed-v1"]

    /// 受信者が依頼の状態を「到着」「完了」に変えたとき、依頼者の端末へ通知が届くよう
    /// 依頼者の Private DB（共有ゾーン）にクエリ購読を登録する。登録済みなら何もしない。
    ///
    /// 通知文は固定の文言にする。レコードのフィールド（受信者名など）は共有の参加者が自由に書けるため、
    /// ロック画面に出る文章へ差し込むと、なりすました文面を表示させられてしまう。
    func ensureRequesterSubscriptions() async throws {
        try await ensureSharingZone()
        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let existing = Set(try await privateDB.allSubscriptions().map(\.subscriptionID))
        let specs: [(id: String, status: ShareStatus, key: String)] = [
            (Self.arrivedSubscriptionID, .fired, "SHARED_MEMO_ARRIVED"),
            (Self.completedSubscriptionID, .completed, "SHARED_MEMO_COMPLETED"),
        ]
        let toSave: [CKSubscription] = specs.filter { !existing.contains($0.id) }.map { spec in
            let subscription = CKQuerySubscription(
                recordType: Self.recordType,
                predicate: NSPredicate(format: "status == %@", spec.status.rawValue),
                subscriptionID: spec.id,
                options: [.firesOnRecordUpdate]
            )
            subscription.zoneID = zoneID
            let info = CKSubscription.NotificationInfo()
            info.titleLocalizationKey = "SHARED_MEMO_UPDATE_TITLE"
            info.alertLocalizationKey = spec.key
            info.soundName = "default"
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            return subscription
        }
        let toDelete = Self.legacySubscriptionIDs.filter(existing.contains)
        guard !toSave.isEmpty || !toDelete.isEmpty else { return }
        _ = try await privateDB.modifySubscriptions(saving: toSave, deleting: toDelete)
    }

    // MARK: - 受信者名の書き込み（招待で送った依頼の相手名）

    /// 招待で送った依頼は受信者が未定のまま保存される。受信者が受け取ったら、
    /// 自分の表示名と userRecordID を書き込む。依頼者側は、この値を共有の参加者と突き合わせ、
    /// 本人が書いた名前のときだけ表示名として使う。
    /// 既に受信者が決まっている、または監視中 (active) でなければ書き込まない
    /// （到着・完了後の更新は依頼者への通知を再び出してしまう）。
    func claimRecipient(recordID: CKRecord.ID, name: String, userRecordName: String) async throws {
        let record = try await sharedDB.record(for: recordID)
        guard ((record["recipientRecordID"] as? String) ?? "").isEmpty,
              (record["status"] as? String) == ShareStatus.active.rawValue
        else { return }
        record["recipientRecordID"] = userRecordName
        record["recipientName"] = name
        _ = try await sharedDB.save(record)
    }

    // MARK: - 受信した依頼から抜ける（受信者）

    /// 受信者が依頼の共有から抜ける。共有ゾーンごと sharedDB から消えるため、
    /// 次回の同期で再び取り込まれない。依頼者側のレコードは残る。
    func leaveReceivedShare(recordID: CKRecord.ID) async throws {
        let record = try await sharedDB.record(for: recordID)
        guard let shareID = record.share?.recordID else { return }
        _ = try await sharedDB.modifyRecords(saving: [], deleting: [shareID])
    }

    // MARK: - Share 受諾（受信者）

    /// `userDidAcceptCloudKitShareWith` から呼び出す。
    /// iOS が `CKShare.Metadata` を渡してくれるので、それを accept する。
    func acceptShare(metadata: CKShare.Metadata) async throws {
        let op = CKAcceptSharesOperation(shareMetadatas: [metadata])
        // 1 件の share で perShareResultBlock と acceptSharesResultBlock の両方が
        // 発火し、continuation を 2 回 resume すると fatal trap になる。
        // acceptSharesResultBlock 側に集約する（per-share の失敗もここに伝わる）。
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // CloudKit の内部キューで呼ばれるため @Sendable（MainActor 隔離を継承させない）
            op.acceptSharesResultBlock = { @Sendable result in
                switch result {
                case .success: cont.resume(returning: ())
                case .failure(let error): cont.resume(throwing: error)
                }
            }
            container.add(op)
        }
    }

    // MARK: - Helpers

    private func fetchAll(
        database: CKDatabase,
        query: CKQuery,
        zoneID: CKRecordZone.ID,
        isMyRequest: Bool
    ) async throws -> [SharedMemoCKData] {
        var all: [(CKRecord.ID, Result<CKRecord, Error>)] = []
        var (batch, cursor) = try await database.records(matching: query, inZoneWith: zoneID)
        all.append(contentsOf: batch)
        while let c = cursor {
            (batch, cursor) = try await database.records(continuingMatchFrom: c)
            all.append(contentsOf: batch)
        }
        return all.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return SharedMemoCKData(from: record, isMyRequest: isMyRequest)
        }
    }
}

// MARK: - SharedMemoCKData
// 新しい CKShare 経由の SharedMemo データ（encryptedValues 対応版）

struct SharedMemoCKData: Sendable {
    let ckRecordID: CKRecord.ID
    let memoTitle: String
    let memoNote: String
    let memoLocationName: String
    let memoLatitude: Double
    let memoLongitude: Double
    let memoRadius: Double
    let memoDeadline: Date?
    let memoTimeWindowStart: Int?
    let memoTimeWindowEnd: Int?
    let requesterName: String
    let recipientRecordID: String
    let recipientName: String
    let autoComplete: Bool
    let status: ShareStatus
    let firedAt: Date?
    let completedAt: Date?
    let createdAt: Date
    let isMyRequest: Bool
    /// ルートレコードに付いている共有 (CKShare) のレコード ID。依頼者側で参加者を調べるのに使う。
    let shareRecordID: CKRecord.ID?

    init(
        ckRecordID: CKRecord.ID, memoTitle: String, memoLocationName: String,
        memoLatitude: Double, memoLongitude: Double, memoRadius: Double,
        memoDeadline: Date?, memoTimeWindowStart: Int?, memoTimeWindowEnd: Int?,
        requesterName: String, recipientRecordID: String, recipientName: String,
        autoComplete: Bool, status: ShareStatus,
        firedAt: Date?, completedAt: Date?, createdAt: Date, isMyRequest: Bool,
        memoNote: String = "",
        shareRecordID: CKRecord.ID? = nil
    ) {
        self.ckRecordID = ckRecordID
        self.memoTitle = memoTitle
        self.memoNote = memoNote
        self.memoLocationName = memoLocationName
        self.memoLatitude = memoLatitude
        self.memoLongitude = memoLongitude
        self.memoRadius = memoRadius
        self.memoDeadline = memoDeadline
        self.memoTimeWindowStart = memoTimeWindowStart
        self.memoTimeWindowEnd = memoTimeWindowEnd
        self.requesterName = requesterName
        self.recipientRecordID = recipientRecordID
        self.recipientName = recipientName
        self.autoComplete = autoComplete
        self.status = status
        self.firedAt = firedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.isMyRequest = isMyRequest
        self.shareRecordID = shareRecordID
    }

    init?(from record: CKRecord, isMyRequest: Bool) {
        guard
            let title       = record.encryptedValues["memoTitle"]        as? String,
            let locName     = record.encryptedValues["memoLocationName"] as? String,
            let lat         = record.encryptedValues["memoLatitude"]     as? Double,
            let lon         = record.encryptedValues["memoLongitude"]    as? Double,
            let radius      = record["memoRadius"]    as? Double,
            let requesterN  = record["requesterName"] as? String,
            let recipientID = record["recipientRecordID"] as? String,
            let recipientN  = record["recipientName"]    as? String,
            let autoInt     = record["autoComplete"]  as? Int,
            let statusStr   = record["status"]        as? String,
            let createdAt   = record["createdAt"]     as? Date
        else { return nil }

        self.ckRecordID          = record.recordID
        self.memoTitle           = title
        // 本文は後から追加した項目。古い依頼レコードには無いので空文字にする。
        self.memoNote            = record.encryptedValues["memoNote"] as? String ?? ""
        self.memoLocationName    = locName
        self.memoLatitude        = lat
        self.memoLongitude       = lon
        self.memoRadius          = radius
        self.memoDeadline        = record["memoDeadline"]        as? Date
        self.memoTimeWindowStart = record["memoTimeWindowStart"] as? Int
        self.memoTimeWindowEnd   = record["memoTimeWindowEnd"]   as? Int
        self.requesterName       = requesterN
        self.recipientRecordID   = recipientID
        self.recipientName       = recipientN
        self.autoComplete        = autoInt == 1
        self.status              = ShareStatus(rawValue: statusStr) ?? .active
        self.firedAt             = record["firedAt"]     as? Date
        self.completedAt         = record["completedAt"] as? Date
        self.createdAt           = createdAt
        self.isMyRequest         = isMyRequest
        self.shareRecordID       = record.share?.recordID
    }
}

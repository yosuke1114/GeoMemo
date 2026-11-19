import CloudKit
import Foundation

/// Private DB + CKShare ベースの SharedMemo 管理サービス。
///
/// 設計方針:
/// - レコードは依頼者の Private DB のカスタムゾーン (`sharingZoneName`) に保存する。
/// - 受信者には `CKShare` を渡し、Apple のフレームワーク側で認可を強制する。
///   → 第三者は Private DB / Shared DB を覗けないため、Public DB 時代の
///   全件列挙・cross-user読み取りが原理的に不可能になる。
/// - 機密度の高いフィールド (`memoLatitude/Longitude/Title/LocationName`)
///   は `record.encryptedValues` に格納して、CloudKit Dashboard上でも非可読化する。
/// - SharedMemo SwiftData モデルはそのままローカルキャッシュとして使用する。
@MainActor
final class CKShareService {
    static let shared = CKShareService()

    let container = CKContainer(identifier: geomemoApp.cloudKitContainerID)
    var privateDB: CKDatabase { container.privateCloudDatabase }
    var sharedDB:  CKDatabase { container.sharedCloudDatabase  }

    nonisolated static let sharingZoneName = "geomemoSharingZone"
    nonisolated static let recordType      = "SharedMemo"  // 旧 SharedMemoRecord と区別

    private var zoneEnsured = false

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

    /// 新しい SharedMemo レコードを作成し、CKShare を生成して返す。
    /// 戻り値の `share` は `UICloudSharingController` に渡して受信者へURLを送信する。
    /// 受信者を事前に participant として追加するため、誰宛てかが share.participants から分かる。
    func createSharedMemoShare(
        from memo: GeoMemo,
        requesterName: String,
        recipientRecordID: String,
        recipientName: String,
        autoComplete: Bool
    ) async throws -> (record: CKRecord, share: CKShare) {
        try await ensureSharingZone()

        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)

        // 機密フィールドのみ encryptedValues に入れる（CK Dashboard でも復号できない）
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
        record["recipientRecordID"]   = recipientRecordID
        record["recipientName"]       = recipientName
        record["autoComplete"]        = autoComplete ? 1 : 0
        record["status"]              = ShareStatus.active.rawValue
        record["createdAt"]           = Date()

        let share = CKShare(rootRecord: record)
        share[CKShare.SystemFieldKey.title] = memo.title.isEmpty
            ? String(localized: "依頼") as CKRecordValue
            : memo.title as CKRecordValue
        // UICloudSharingController が participant 招待UI（連絡先/メッセージ送信）を担う。
        // publicPermission=.none のままだと参加者ゼロで share できないので、
        // .readWrite で「URL を受信した特定の招待者が記録を読み書き可能」とする。
        // 機密フィールドは encryptedValues で守られているため、URL が漏れても
        // 招待者でない第三者は内容を復号できない。
        share.publicPermission = .readWrite

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
        return (savedRecord, savedShare)
    }

    // MARK: - ステータス更新

    /// 依頼者・受信者どちらからでも呼べる（CKShare の writePermission 次第）。
    /// zoneID.ownerName から先に DB を確定し、`.unknownItem` の時だけもう一方へ
    /// フォールバックする。permission error など他のエラーは呼び出し元へ伝播。
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
        let predicate = NSPredicate(format: "status IN %@", allStatuses)
        return await withTaskGroup(of: [SharedMemoCKData].self) { group in
            for zone in zones {
                group.addTask {
                    do {
                        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
                        return try await self.fetchAll(database: self.sharedDB, query: query, zoneID: zone.zoneID, isMyRequest: false)
                    } catch {
                        // 個別ゾーンの失敗は無視して継続。デバッグ目的のみログ。
                        print("[CKShareService] zone \(zone.zoneID) fetch failed: \(error)")
                        return []
                    }
                }
            }
            var all: [SharedMemoCKData] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
    }

    // MARK: - 依頼者への通知（CloudKit の購読）

    nonisolated static let arrivedSubscriptionID   = "requester-arrived-v1"
    nonisolated static let completedSubscriptionID = "requester-completed-v1"

    /// 受信者が依頼の状態を「到着」「完了」に変えたとき、依頼者の端末へ通知が届くよう
    /// 依頼者の Private DB（共有ゾーン）にクエリ購読を登録する。登録済みなら何もしない。
    /// 本文は暗号化フィールドなので通知には含められない。受信者名だけを差し込む。
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
            info.alertLocalizationArgs = ["recipientName"]
            info.soundName = "default"
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            return subscription
        }
        guard !toSave.isEmpty else { return }
        _ = try await privateDB.modifySubscriptions(saving: toSave, deleting: [])
    }

    // MARK: - 受信者名の書き込み（「リンクで送る」の相手名）

    /// 「リンクで送る」で作られた依頼は受信者が未定のまま保存される。受信者が受け取ったら、
    /// 自分の表示名と userRecordID を書き込み、依頼者の一覧や通知に名前が出るようにする。
    /// 既に受信者が決まっていれば何もしない。
    func claimRecipient(recordID: CKRecord.ID, name: String, userRecordName: String) async throws {
        let record = try await sharedDB.record(for: recordID)
        guard ((record["recipientRecordID"] as? String) ?? "").isEmpty else { return }
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
            op.acceptSharesResultBlock = { result in
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

    init(
        ckRecordID: CKRecord.ID, memoTitle: String, memoLocationName: String,
        memoLatitude: Double, memoLongitude: Double, memoRadius: Double,
        memoDeadline: Date?, memoTimeWindowStart: Int?, memoTimeWindowEnd: Int?,
        requesterName: String, recipientRecordID: String, recipientName: String,
        autoComplete: Bool, status: ShareStatus,
        firedAt: Date?, completedAt: Date?, createdAt: Date, isMyRequest: Bool,
        memoNote: String = ""
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
    }
}

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

    static let sharingZoneName = "geomemoSharingZone"
    static let recordType      = "SharedMemo"  // 旧 SharedMemoRecord と区別

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

        // 機密フィールドは encryptedValues に
        record.encryptedValues["memoTitle"]        = memo.title
        record.encryptedValues["memoLocationName"] = memo.locationName
        record.encryptedValues["memoLatitude"]     = memo.latitude
        record.encryptedValues["memoLongitude"]    = memo.longitude

        // 非機密フィールド
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

        // record と share を1回のオペレーションで保存（アトミック）
        let (results, _) = try await privateDB.modifyRecords(
            saving: [record, share], deleting: []
        )
        for (_, result) in results {
            _ = try result.get()
        }
        return (record, share)
    }

    // MARK: - ステータス更新

    /// 依頼者・受信者どちらからでも呼べる（CKShare の writePermission 次第）。
    /// レコードがどちらのDBに居るかわからないので、両方を試す。
    func updateStatus(recordID: CKRecord.ID, status: ShareStatus, date: Date? = nil) async throws {
        let record: CKRecord
        do {
            record = try await privateDB.record(for: recordID)
        } catch {
            record = try await sharedDB.record(for: recordID)
        }
        record["status"] = status.rawValue
        switch status {
        case .fired:     record["firedAt"]     = date
        case .completed: record["completedAt"] = date
        default: break
        }
        // どちらのDBから来たかで保存先も決まる
        let scope = record.recordID.zoneID.ownerName == CKCurrentUserDefaultName
            ? privateDB : sharedDB
        _ = try await scope.save(record)
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
    /// 他人のゾーンは見えないので、まずゾーン一覧を取得して各ゾーンを走査する。
    func fetchReceivedSharedMemos() async throws -> [SharedMemoCKData] {
        let zones = try await sharedDB.allRecordZones()
        var results: [SharedMemoCKData] = []
        for zone in zones {
            let predicate = NSPredicate(format: "status != %@", ShareStatus.cancelled.rawValue)
            let query = CKQuery(recordType: Self.recordType, predicate: predicate)
            let zoneResults = try await fetchAll(database: sharedDB, query: query, zoneID: zone.zoneID, isMyRequest: false)
            results.append(contentsOf: zoneResults)
        }
        return results
    }

    // MARK: - Share 受諾（受信者）

    /// `userDidAcceptCloudKitShareWith` から呼び出す。
    /// iOS が `CKShare.Metadata` を渡してくれるので、それを accept する。
    func acceptShare(metadata: CKShare.Metadata) async throws {
        let op = CKAcceptSharesOperation(shareMetadatas: [metadata])
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.perShareResultBlock = { _, result in
                if case .failure(let error) = result {
                    cont.resume(throwing: error)
                }
            }
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
        firedAt: Date?, completedAt: Date?, createdAt: Date, isMyRequest: Bool
    ) {
        self.ckRecordID = ckRecordID
        self.memoTitle = memoTitle
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

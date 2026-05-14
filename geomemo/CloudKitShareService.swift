import CloudKit
import Foundation
import SwiftData

// MARK: - CloudKit Share Service
// CloudKit Public DB を使った SharedMemo 管理

@MainActor
final class CloudKitShareService {
    static let shared = CloudKitShareService()

    private let container = CKContainer(identifier: geomemoApp.cloudKitContainerID)
    private var publicDB: CKDatabase { container.publicCloudDatabase }

    static let recordType = "SharedMemoRecord"

    // MARK: - 依頼を作成（依頼者）

    func createSharedMemo(
        from memo: GeoMemo,
        requesterProfile: UserProfile,
        recipient: FriendConnection,
        autoComplete: Bool
    ) async throws -> String {
        let recordName = UUID().uuidString
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: recordName)
        )
        record["memoTitle"]           = memo.title as CKRecordValue
        record["memoLocationName"]    = memo.locationName as CKRecordValue
        record["memoLatitude"]        = memo.latitude as CKRecordValue
        record["memoLongitude"]       = memo.longitude as CKRecordValue
        record["memoRadius"]          = memo.radius as CKRecordValue
        record["memoDeadline"]        = memo.deadline as CKRecordValue?
        record["memoTimeWindowStart"] = memo.timeWindowStart.map { $0 as CKRecordValue }
        record["memoTimeWindowEnd"]   = memo.timeWindowEnd.map { $0 as CKRecordValue }
        record["requesterRecordID"]   = requesterProfile.iCloudRecordID as CKRecordValue
        record["requesterName"]       = requesterProfile.displayName as CKRecordValue
        record["recipientRecordID"]   = recipient.friendRecordID as CKRecordValue
        record["recipientName"]       = recipient.friendDisplayName as CKRecordValue
        record["autoComplete"]        = (autoComplete ? 1 : 0) as CKRecordValue
        record["status"]              = ShareStatus.active.rawValue as CKRecordValue
        record["createdAt"]           = Date() as CKRecordValue
        _ = try await publicDB.save(record)
        return recordName
    }

    // MARK: - 自分宛ての SharedMemo を取得（受信者）

    func fetchReceivedSharedMemos(myRecordID: String) async throws -> [SharedMemoData] {
        let predicate = NSPredicate(
            format: "recipientRecordID == %@ AND status != %@",
            myRecordID, ShareStatus.cancelled.rawValue
        )
        return try await fetchRecords(predicate: predicate, isMyRequest: false)
    }

    // MARK: - 自分が送った SharedMemo を取得（依頼者）

    func fetchSentSharedMemos(myRecordID: String) async throws -> [SharedMemoData] {
        let predicate = NSPredicate(
            format: "requesterRecordID == %@ AND status != %@",
            myRecordID, ShareStatus.cancelled.rawValue
        )
        return try await fetchRecords(predicate: predicate, isMyRequest: true)
    }

    // MARK: - ステータス更新

    func updateStatus(_ ckRecordName: String, status: ShareStatus, date: Date? = nil) async throws {
        let record = try await publicDB.record(for: CKRecord.ID(recordName: ckRecordName))
        record["status"] = status.rawValue as CKRecordValue
        switch status {
        case .fired:     record["firedAt"]     = date as CKRecordValue?
        case .completed: record["completedAt"] = date as CKRecordValue?
        default: break
        }
        _ = try await publicDB.save(record)
    }

    // MARK: - 削除（キャンセル）

    func cancelSharedMemo(_ ckRecordName: String) async throws {
        try await updateStatus(ckRecordName, status: .cancelled)
    }

    // MARK: - Private helpers

    private func fetchRecords(predicate: NSPredicate, isMyRequest: Bool) async throws -> [SharedMemoData] {
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        var allResults: [(CKRecord.ID, Result<CKRecord, Error>)] = []
        var (batch, cursor) = try await publicDB.records(matching: query)
        allResults.append(contentsOf: batch)
        while let c = cursor {
            (batch, cursor) = try await publicDB.records(continuingMatchFrom: c)
            allResults.append(contentsOf: batch)
        }
        return allResults.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return SharedMemoData(from: record, isMyRequest: isMyRequest)
        }
    }
}

// MARK: - SharedMemoData（CK レコードから SwiftData 用データに変換）

struct SharedMemoData {
    let ckRecordName: String
    let memoTitle: String
    let memoLocationName: String
    let memoLatitude: Double
    let memoLongitude: Double
    let memoRadius: Double
    let memoDeadline: Date?
    let memoTimeWindowStart: Int?
    let memoTimeWindowEnd: Int?
    let requesterRecordID: String
    let requesterName: String
    let recipientRecordID: String
    let recipientName: String
    let autoComplete: Bool
    let status: ShareStatus
    let firedAt: Date?
    let completedAt: Date?
    let isMyRequest: Bool

    init?(from record: CKRecord, isMyRequest: Bool) {
        guard
            let title       = record["memoTitle"] as? String,
            let locName     = record["memoLocationName"] as? String,
            let lat         = record["memoLatitude"] as? Double,
            let lon         = record["memoLongitude"] as? Double,
            let radius      = record["memoRadius"] as? Double,
            let requesterID = record["requesterRecordID"] as? String,
            let requesterN  = record["requesterName"] as? String,
            let recipientID = record["recipientRecordID"] as? String,
            let recipientN  = record["recipientName"] as? String,
            let autoInt     = record["autoComplete"] as? Int,
            let statusStr   = record["status"] as? String
        else { return nil }

        self.ckRecordName        = record.recordID.recordName
        self.memoTitle           = title
        self.memoLocationName    = locName
        self.memoLatitude        = lat
        self.memoLongitude       = lon
        self.memoRadius          = radius
        self.memoDeadline        = record["memoDeadline"] as? Date
        self.memoTimeWindowStart = record["memoTimeWindowStart"] as? Int
        self.memoTimeWindowEnd   = record["memoTimeWindowEnd"] as? Int
        self.requesterRecordID   = requesterID
        self.requesterName       = requesterN
        self.recipientRecordID   = recipientID
        self.recipientName       = recipientN
        self.autoComplete        = autoInt == 1
        self.status              = ShareStatus(rawValue: statusStr) ?? .active
        self.firedAt             = record["firedAt"] as? Date
        self.completedAt         = record["completedAt"] as? Date
        self.isMyRequest         = isMyRequest
    }
}

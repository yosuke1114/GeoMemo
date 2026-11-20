import CloudKit
import Foundation

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

// MARK: - SharingZoneConfig
// CKShareService は iPhone 専用なので、SharedMemo（Watch とも共有するモデル）が参照する定数だけここに置く。

nonisolated enum SharingZoneConfig {
    nonisolated static let zoneName = "geomemoSharingZone"
}

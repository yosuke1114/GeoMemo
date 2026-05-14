import CloudKit
import Foundation

// MARK: - CloudKit Friend Service
// CloudKit Public DB を使ったフレンド招待管理

@MainActor
final class CloudKitFriendService {
    static let shared = CloudKitFriendService()

    private let container = CKContainer(identifier: geomemoApp.cloudKitContainerID)
    private var publicDB: CKDatabase { container.publicCloudDatabase }

    static let invitationRecordType = "FriendInvitation"
    static let invitationTTL: TimeInterval = 48 * 3600  // 48時間

    // MARK: - My iCloud Record ID

    func fetchMyRecordID() async throws -> String {
        do {
            let recordID = try await container.userRecordID()
            return recordID.recordName
        } catch let error as CKError where error.code == .notAuthenticated {
            throw FriendServiceError.notSignedIn
        }
    }

    // MARK: - iCloud 利用可能チェック

    /// CloudKit アカウントが利用可能か（iCloud Drive ではなく CloudKit 側を確認する）
    func checkAvailability() async -> Bool {
        do {
            return try await container.accountStatus() == .available
        } catch {
            return false
        }
    }

    // MARK: - 招待コード生成 & Public DB 書き込み

    func createInvitation(code: String, myRecordID: String, myName: String) async throws {
        let ckRecordID = CKRecord.ID(recordName: code)
        let record = CKRecord(recordType: Self.invitationRecordType, recordID: ckRecordID)
        record["code"] = code as CKRecordValue
        record["requesterRecordID"] = myRecordID as CKRecordValue
        record["requesterName"] = myName as CKRecordValue
        record["accepted"] = 0 as CKRecordValue          // Bool → Int (CK互換)
        record["accepterRecordID"] = "" as CKRecordValue
        record["accepterName"] = "" as CKRecordValue
        record["expiresAt"] = Date().addingTimeInterval(Self.invitationTTL) as CKRecordValue
        _ = try await publicDB.save(record)
    }

    // MARK: - 招待コードの読み取り（受信者側）

    func fetchInvitation(code: String) async throws -> (requesterID: String, requesterName: String) {
        let ckRecordID = CKRecord.ID(recordName: code)
        let record = try await publicDB.record(for: ckRecordID)

        guard
            let requesterID   = record["requesterRecordID"] as? String,
            let requesterName = record["requesterName"] as? String,
            let expiresAt     = record["expiresAt"] as? Date,
            !requesterID.isEmpty,
            expiresAt > Date()
        else {
            throw FriendServiceError.invitationExpiredOrInvalid
        }
        return (requesterID, requesterName)
    }

    // MARK: - 招待を承認（受信者側）

    func acceptInvitation(code: String, myRecordID: String, myName: String) async throws {
        let ckRecordID = CKRecord.ID(recordName: code)
        let record = try await publicDB.record(for: ckRecordID)
        record["accepted"] = 1 as CKRecordValue
        record["accepterRecordID"] = myRecordID as CKRecordValue
        record["accepterName"] = myName as CKRecordValue
        _ = try await publicDB.save(record)
    }

    // MARK: - 承認済み招待の取得（送信者側・ポーリング）

    func fetchAcceptedInvitations(myRecordID: String) async throws -> [(accepterID: String, accepterName: String, code: String)] {
        let predicate = NSPredicate(
            format: "requesterRecordID == %@ AND accepted == 1",
            myRecordID
        )
        let query = CKQuery(recordType: Self.invitationRecordType, predicate: predicate)
        let (results, _) = try await publicDB.records(matching: query)

        return results.compactMap { _, result in
            guard
                let record      = try? result.get(),
                let accepterID  = record["accepterRecordID"] as? String,
                let accepterName = record["accepterName"] as? String,
                !accepterID.isEmpty
            else { return nil }
            return (accepterID, accepterName, record.recordID.recordName)
        }
    }

    // MARK: - 招待レコード削除（処理完了後）

    func deleteInvitation(code: String) async throws {
        try await publicDB.deleteRecord(withID: CKRecord.ID(recordName: code))
    }

    // MARK: - Errors

    enum FriendServiceError: LocalizedError {
        case invitationExpiredOrInvalid
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .invitationExpiredOrInvalid:
                return String(localized: "この招待リンクは無効または期限切れです。")
            case .notSignedIn:
                return String(localized: "iCloudにサインインしてください。")
            }
        }
    }
}

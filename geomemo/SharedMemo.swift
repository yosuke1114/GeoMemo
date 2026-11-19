import Foundation
import SwiftData
import CoreLocation
import CloudKit

// MARK: - ShareStatus

enum ShareStatus: String, Codable {
    case active     // 監視中
    case fired      // 発火済み（手動完了待ち）
    case completed  // 完了
    case cancelled  // キャンセル
}

// MARK: - SharedMemo Model（送受信メモのローカルキャッシュ）

@Model final class SharedMemo {
    var id: UUID = UUID()
    var ckRecordName: String = ""       // CloudKit レコード名（同期用）

    // メモ内容スナップショット
    var memoTitle: String = ""
    var memoLocationName: String = ""
    var memoLatitude: Double = 0.0
    var memoLongitude: Double = 0.0
    var memoRadius: Double = 100.0
    var memoDeadline: Date? = nil
    var memoTimeWindowStart: Int? = nil
    var memoTimeWindowEnd: Int? = nil

    // 関係者
    var requesterRecordID: String = ""
    var requesterName: String = ""
    var recipientRecordID: String = ""
    var recipientName: String = ""

    // 設定・状態
    var autoComplete: Bool = false
    var statusRaw: String = ShareStatus.active.rawValue
    var firedAt: Date? = nil
    var completedAt: Date? = nil
    var createdAt: Date = Date()

    /// true = 自分が依頼した（送信側）、false = 受け取った（受信側）
    var isMyRequest: Bool = false

    init(
        ckRecordName: String,
        memoTitle: String,
        memoLocationName: String,
        memoLatitude: Double,
        memoLongitude: Double,
        memoRadius: Double,
        memoDeadline: Date? = nil,
        memoTimeWindowStart: Int? = nil,
        memoTimeWindowEnd: Int? = nil,
        requesterRecordID: String,
        requesterName: String,
        recipientRecordID: String,
        recipientName: String,
        autoComplete: Bool,
        isMyRequest: Bool,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        status: ShareStatus = .active,
        firedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.ckRecordName = ckRecordName
        self.memoTitle = memoTitle
        self.memoLocationName = memoLocationName
        self.memoLatitude = memoLatitude
        self.memoLongitude = memoLongitude
        self.memoRadius = memoRadius
        self.memoDeadline = memoDeadline
        self.memoTimeWindowStart = memoTimeWindowStart
        self.memoTimeWindowEnd = memoTimeWindowEnd
        self.requesterRecordID = requesterRecordID
        self.requesterName = requesterName
        self.recipientRecordID = recipientRecordID
        self.recipientName = recipientName
        self.autoComplete = autoComplete
        self.isMyRequest = isMyRequest
        self.createdAt = createdAt
        self.statusRaw = status.rawValue
        self.firedAt = firedAt
        self.completedAt = completedAt
    }

    // MARK: - Computed

    var status: ShareStatus {
        get { ShareStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: memoLatitude, longitude: memoLongitude)
    }

    static let geofencePrefix = "shared_"

    /// LocationManager のジオフェンス識別子（通常メモ・ルートと区別するプレフィックス）
    var geofenceIdentifier: String { "\(SharedMemo.geofencePrefix)\(id.uuidString)" }

    var isActive: Bool { status == .active || status == .fired }

    /// CKShare 共有ゾーンの所有者名（自分の依頼=自分、受け取った依頼=依頼者）
    var zoneOwnerName: String {
        isMyRequest ? CKCurrentUserDefaultName : requesterRecordID
    }

    /// CloudKit 操作で使う完全な CKRecord.ID（zone owner も含む）
    var cloudKitRecordID: CKRecord.ID {
        let zoneID = CKRecordZone.ID(zoneName: CKShareService.sharingZoneName, ownerName: zoneOwnerName)
        return CKRecord.ID(recordName: ckRecordName, zoneID: zoneID)
    }

    /// CloudKit から取得したデータでローカルフィールドを更新する。
    /// 変更がなかった場合は `false` を返してデータストアの不要な dirty 化を防ぐ。
    ///
    /// - タイトル・期限は受け取った依頼（`isMyRequest == false`）にだけ反映する。共有の参加者は
    ///   レコードを書き換えられるため、自分が送った依頼の表示を相手に書き換えさせない。
    ///   また依頼者側は自分の編集が正なので、索引が古い CKQuery の結果で編集が戻るのも防げる。
    /// - 受信者の名前・ID はここでは扱わない（依頼者側は共有の参加者から `applyVerifiedRecipient` で決める）。
    /// - 状態は後戻りさせない（`ShareStatus.shouldAccept`）。
    @discardableResult
    func apply(_ data: SharedMemoCKData) -> Bool {
        var changed = false
        if !isMyRequest {
            // 依頼者が送信後に編集した内容（タイトル・期限）を受信側へ反映する
            if memoTitle != data.memoTitle {
                memoTitle = data.memoTitle
                changed = true
            }
            if memoDeadline != data.memoDeadline {
                memoDeadline = data.memoDeadline
                changed = true
            }
        }
        guard ShareStatus.shouldAccept(data.status, over: status),
              status != data.status || firedAt != data.firedAt || completedAt != data.completedAt
        else { return changed }
        status      = data.status
        firedAt     = data.firedAt
        completedAt = data.completedAt
        return true
    }

    /// 依頼者側で、共有の参加者から確定した受信者を反映する。
    /// - Returns: `changed` = 値が変わった、`isNewRecipient` = 受信者の ID が新しく決まった（または変わった）
    @discardableResult
    func applyVerifiedRecipient(_ recipient: VerifiedRecipient) -> (changed: Bool, isNewRecipient: Bool) {
        guard isMyRequest, !recipient.userRecordName.isEmpty else { return (false, false) }
        let isNewRecipient = recipientRecordID != recipient.userRecordName
        var changed = false
        if isNewRecipient {
            recipientRecordID = recipient.userRecordName
            changed = true
        }
        if !recipient.displayName.isEmpty, recipientName != recipient.displayName {
            recipientName = recipient.displayName
            changed = true
        } else if isNewRecipient, recipient.displayName.isEmpty {
            // 名前が分からない新しい受信者。前の相手の名前（や「リンクで共有」）を残さない
            recipientName = String(localized: "相手")
            changed = true
        }
        return (changed, isNewRecipient)
    }
}

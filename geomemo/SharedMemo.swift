import Foundation
import SwiftData
import CoreLocation

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
        isMyRequest: Bool
    ) {
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
    }

    // MARK: - Computed

    var status: ShareStatus {
        get { ShareStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: memoLatitude, longitude: memoLongitude)
    }

    /// LocationManager のジオフェンス識別子（通常メモ・ルートと区別するプレフィックス）
    var geofenceIdentifier: String { "shared_\(id.uuidString)" }

    var isActive: Bool { status == .active || status == .fired }
}

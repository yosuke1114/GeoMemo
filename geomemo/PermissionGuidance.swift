import Foundation
import CoreLocation
import UserNotifications

// 許可の状態から「何を案内するか」を決める純粋なロジック (テスト対象)。
// 画面・システム API には依存しない。CLAuthorizationStatus などからの変換だけをここに置く。

/// 位置情報の許可の段階。
enum LocationAccess: Equatable {
    case notDetermined
    case deniedOrRestricted
    case whenInUse
    case always

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorizedWhenInUse: self = .whenInUse
        case .authorizedAlways: self = .always
        default: self = .deniedOrRestricted
        }
    }

    var isAuthorized: Bool { self == .whenInUse || self == .always }
}

/// 通知の許可の段階。provisional / ephemeral は「届く」ので allowed に含める。
enum NotificationAccess: Equatable {
    case notDetermined
    case denied
    case allowed

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        default: self = .allowed
        }
    }
}

struct PermissionSnapshot: Equatable {
    var location: LocationAccess
    /// 「正確な位置情報」がオンか。オフ（おおよその位置）だと小さな範囲の到着判定が当てにならない。
    var isPreciseLocation: Bool
    var notification: NotificationAccess
}

/// 地図のバナーが案内する許可の不足。1 つずつ、重要な順に出す。
enum PermissionNotice: String, Equatable, CaseIterable {
    case locationDenied
    case locationNotDetermined
    case locationWhenInUseOnly
    case locationReducedAccuracy
    case notificationsDenied
    case notificationsNotDetermined

    /// バナーのボタンが何をするか。
    enum Action: Equatable {
        case requestLocation       // まだ尋ねていない。ボタンを押したときにだけ許可ダイアログを出す
        case requestNotifications  // 同上
        case openSettings          // 尋ね済み。設定アプリでしか変えられない
    }

    var action: Action {
        switch self {
        case .locationNotDetermined: return .requestLocation
        case .notificationsNotDetermined: return .requestNotifications
        default: return .openSettings
        }
    }

    /// いちばん重要な不足を 1 つ返す。足りていなければ nil。
    static func resolve(_ s: PermissionSnapshot) -> PermissionNotice? {
        switch s.location {
        case .deniedOrRestricted: return .locationDenied
        case .notDetermined: return .locationNotDetermined
        case .whenInUse: return .locationWhenInUseOnly
        case .always: if !s.isPreciseLocation { return .locationReducedAccuracy }
        }
        switch s.notification {
        case .denied: return .notificationsDenied
        case .notDetermined: return .notificationsNotDetermined
        case .allowed: return nil
        }
    }
}

/// iOS のジオフェンス監視の上限に対する使用状況。
enum MonitoringLimitState: Equatable {
    case ok
    case nearLimit(used: Int)
    case overLimit(used: Int, unmonitored: Int)

    /// 残りがこれ以下になったら「そろそろ上限」と知らせる。
    static let nearThreshold = 2

    static func resolve(requiredRegions: Int, limit: Int = 20) -> MonitoringLimitState {
        if requiredRegions > limit {
            return .overLimit(used: requiredRegions, unmonitored: requiredRegions - limit)
        }
        if requiredRegions >= limit - nearThreshold {
            return .nearLimit(used: requiredRegions)
        }
        return .ok
    }
}

/// 地図の上部に出す案内 1 件。
enum MapGuidance: Equatable {
    case permission(PermissionNotice)
    case monitoringLimit(MonitoringLimitState)

    /// 「閉じたら一定期間出さない」の記録に使う識別子。
    var dismissalKey: String {
        switch self {
        case .permission(let notice): return "permission.\(notice.rawValue)"
        case .monitoringLimit(.overLimit): return "limit.over"
        case .monitoringLimit: return "limit.near"
        }
    }

    /// 閉じたあと、同じ案内を出さない期間（1 週間）。
    static let dismissalInterval: TimeInterval = 7 * 24 * 60 * 60

    static func isSuppressed(_ guidance: MapGuidance, dismissedKey: String?, dismissedAt: Date?, now: Date = Date()) -> Bool {
        guard let dismissedKey, let dismissedAt, dismissedKey == guidance.dismissalKey else { return false }
        let elapsed = now.timeIntervalSince(dismissedAt)
        return elapsed >= 0 && elapsed < dismissalInterval
    }

    /// 許可の不足を最優先に、次に監視上限。閉じられて期間内のものは飛ばして次の候補を見る。
    static func resolve(
        permissions: PermissionSnapshot,
        requiredRegions: Int,
        dismissedKey: String?,
        dismissedAt: Date?,
        now: Date = Date()
    ) -> MapGuidance? {
        var candidates: [MapGuidance] = []
        if let notice = PermissionNotice.resolve(permissions) {
            candidates.append(.permission(notice))
        }
        let limit = MonitoringLimitState.resolve(requiredRegions: requiredRegions)
        if limit != .ok { candidates.append(.monitoringLimit(limit)) }
        return candidates.first {
            !isSuppressed($0, dismissedKey: dismissedKey, dismissedAt: dismissedAt, now: now)
        }
    }
}

/// オンボーディングの順序: ようこそ → 使用中 → 常に（理由つき・あとでも可）→ 通知。
enum OnboardingStep: Int, CaseIterable, Equatable {
    case welcome, whenInUse, always, notifications

    /// 次の段階。nil はオンボーディング完了。
    /// 「常に」は、使用中が許可されたときだけ出す（拒否された・既に常にのときは飛ばす）。
    static func next(after step: OnboardingStep, location: LocationAccess) -> OnboardingStep? {
        switch step {
        case .welcome: return .whenInUse
        case .whenInUse: return location == .whenInUse ? .always : .notifications
        case .always: return .notifications
        case .notifications: return nil
        }
    }
}

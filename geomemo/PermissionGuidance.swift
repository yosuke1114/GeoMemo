import Foundation
import CoreLocation
import UserNotifications

// 許可の状態から「何を案内するか」を決める純粋なロジック (テスト対象)。
// 画面・システム API には依存しない。CLAuthorizationStatus などからの変換だけをここに置く。

/// 位置情報の許可の段階。
nonisolated enum LocationAccess: Equatable {
    case notDetermined
    /// ユーザーが拒否した（設定アプリで変えられる）。
    case denied
    /// 保護者による制限などで、ユーザーが変えられない。
    case restricted
    case whenInUse
    case always

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorizedWhenInUse: self = .whenInUse
        case .authorizedAlways: self = .always
        case .restricted: self = .restricted
        default: self = .denied
        }
    }

    var isAuthorized: Bool { self == .whenInUse || self == .always }
}

/// 通知の許可の段階。provisional / ephemeral は「届く」ので allowed に含める。
/// unknown は、システムから状態をまだ読み込めていない間（案内は出さない）。
nonisolated enum NotificationAccess: Equatable {
    case unknown
    case notDetermined
    case denied
    case allowed

    init(_ status: UNAuthorizationStatus?) {
        switch status {
        case nil: self = .unknown
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        default: self = .allowed
        }
    }
}

nonisolated struct PermissionSnapshot: Equatable {
    var location: LocationAccess
    /// 「正確な位置情報」がオンか。オフ（おおよその位置）だと小さな範囲の到着判定が当てにならない。
    var isPreciseLocation: Bool
    var notification: NotificationAccess
}

/// 地図のバナーが案内する許可の不足。1 つずつ、重要な順に出す。
nonisolated enum PermissionNotice: String, Equatable, CaseIterable {
    case locationDenied
    case locationRestricted
    case locationNotDetermined
    case locationWhenInUseOnly
    case locationReducedAccuracy
    case notificationsDenied
    case notificationsNotDetermined

    /// バナーのボタンが何をするか。
    enum Action: Equatable {
        case requestLocation       // まだ尋ねていない。ボタンを押したときにだけ許可ダイアログを出す
        case requestAlways         // 使用中のみ。「常に」のダイアログを試み、出なければ設定アプリを開く
        case requestNotifications  // 同上
        case openSettings          // 尋ね済み。設定アプリでしか変えられない
    }

    /// ボタンの動作。nil はボタンなし（ユーザーが変えられない状態）。
    var action: Action? {
        switch self {
        case .locationNotDetermined: return .requestLocation
        case .locationWhenInUseOnly: return .requestAlways
        case .notificationsNotDetermined: return .requestNotifications
        case .locationRestricted: return nil
        default: return .openSettings
        }
    }

    /// 足りない許可を重要な順にすべて返す。
    static func resolveAll(_ s: PermissionSnapshot) -> [PermissionNotice] {
        var result: [PermissionNotice] = []
        switch s.location {
        case .denied: result.append(.locationDenied)
        case .restricted: result.append(.locationRestricted)
        case .notDetermined: result.append(.locationNotDetermined)
        case .whenInUse: result.append(.locationWhenInUseOnly)
        case .always: if !s.isPreciseLocation { result.append(.locationReducedAccuracy) }
        }
        switch s.notification {
        case .denied: result.append(.notificationsDenied)
        case .notDetermined: result.append(.notificationsNotDetermined)
        case .allowed, .unknown: break
        }
        return result
    }

    /// いちばん重要な不足を 1 つ返す。足りていなければ nil。
    static func resolve(_ s: PermissionSnapshot) -> PermissionNotice? {
        resolveAll(s).first
    }
}

/// iOS のジオフェンス監視の上限に対する使用状況。
nonisolated enum MonitoringLimitState: Equatable {
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

    /// 1 件のメモが登録するジオフェンスの数。経由地が 2 未満のルートは登録されない
    /// （LocationManager.startMonitoringRoute と同じ条件）。
    static func regionCount(isRoute: Bool, waypointCount: Int) -> Int {
        isRoute ? (waypointCount >= 2 ? waypointCount : 0) : 1
    }
}

/// 地図の上部に出す案内 1 件。
nonisolated enum MapGuidance: Equatable {
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

    /// 閉じた時刻（案内の識別子ごと）。1 つ閉じても、ほかの案内の記録は消えない。
    static func isSuppressed(_ guidance: MapGuidance, dismissals: [String: TimeInterval], now: Date = Date()) -> Bool {
        guard let at = dismissals[guidance.dismissalKey] else { return false }
        let elapsed = now.timeIntervalSince1970 - at
        return elapsed >= 0 && elapsed < dismissalInterval
    }

    /// 閉じた記録を追加する。期間を過ぎた古い記録は捨てる。
    static func recordingDismissal(of guidance: MapGuidance, in dismissals: [String: TimeInterval], now: Date = Date()) -> [String: TimeInterval] {
        var result = dismissals.filter { _, at in
            let elapsed = now.timeIntervalSince1970 - at
            return elapsed >= 0 && elapsed < dismissalInterval
        }
        result[guidance.dismissalKey] = now.timeIntervalSince1970
        return result
    }

    /// UserDefaults（@AppStorage）に JSON 文字列で保存するための変換。壊れていたら空。
    static func decodeDismissals(_ json: String) -> [String: TimeInterval] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else { return [:] }
        return dict
    }

    static func encodeDismissals(_ dismissals: [String: TimeInterval]) -> String {
        guard let data = try? JSONEncoder().encode(dismissals),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// 許可の不足を最優先に、次に監視上限。閉じられて期間内のものは飛ばして次の候補を見る。
    static func resolve(
        permissions: PermissionSnapshot,
        requiredRegions: Int,
        dismissals: [String: TimeInterval],
        now: Date = Date()
    ) -> MapGuidance? {
        var candidates: [MapGuidance] = PermissionNotice.resolveAll(permissions).map { .permission($0) }
        let limit = MonitoringLimitState.resolve(requiredRegions: requiredRegions)
        if limit != .ok { candidates.append(.monitoringLimit(limit)) }
        return candidates.first { !isSuppressed($0, dismissals: dismissals, now: now) }
    }
}

/// オンボーディングの順序: ようこそ → 使用中 → 常に（理由つき・あとでも可）→ 通知。
nonisolated enum OnboardingStep: Int, CaseIterable, Equatable {
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

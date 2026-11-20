import Foundation

/// 「最後に場所への出入りを検知した時刻」と「最後に通知を出した時刻」の端末内の記録（診断用）。
///
/// 記録するのは時刻（timeIntervalSince1970）だけ。メモの ID・領域の識別子・座標は保存しない。
/// 端末の外には送らない。App Group にはせず（ウィジェットから読まない）、標準の UserDefaults に置く。
/// 検知から通知までは条件で止まることがあり（完了済み・期限・曜日・アプリ内の通知スイッチなど）、
/// 2 つを分けて持つことで「検知はあるが通知を出していない」と「検知そのものが無い」を見分けられる。
nonisolated struct DiagnosticsLog {
    static let regionEventKey = "diagnostics.lastRegionEventAt"
    static let notificationKey = "diagnostics.lastNotificationAt"

    static let shared = DiagnosticsLog(defaults: .standard)

    // UserDefaults はスレッドセーフ（CLLocationManager のデリゲートなど MainActor 外からも呼ぶ）
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var lastRegionEventAt: Date? { read(Self.regionEventKey) }
    var lastNotificationAt: Date? { read(Self.notificationKey) }

    func recordRegionEvent(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.regionEventKey)
    }

    func recordNotification(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.notificationKey)
    }

    private func read(_ key: String) -> Date? {
        guard let value = defaults.object(forKey: key) as? Double else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}

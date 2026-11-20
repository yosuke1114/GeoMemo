import Foundation

/// `geomemo://` の URL が表す操作。ウィジェット・コントロールからの起動に使う。
/// URL の組み立て側（`geomemoWidget.swift` の `WidgetDeepLink`）と scheme / host をそろえること。
nonisolated enum DeepLinkRoute: Equatable {
    case memo(UUID)
    case favorites
    case search(String)
    /// 新しいメモの作成を始める（コントロール・ロック画面ウィジェットから）。
    case newMemo

    nonisolated static let scheme = "geomemo"

    nonisolated enum Host {
        static let memo = "memo"
        static let favorites = "favorites"
        static let search = "search"
        static let new = "new"
    }

    nonisolated static func parse(_ url: URL) -> DeepLinkRoute? {
        guard url.scheme == scheme else { return nil }
        switch url.host {
        case Host.memo:
            guard let idString = url.pathComponents.dropFirst().first,
                  let uuid = UUID(uuidString: idString) else { return nil }
            return .memo(uuid)
        case Host.favorites:
            return .favorites
        case Host.search:
            guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value else { return nil }
            return .search(query)
        case Host.new:
            return .newMemo
        default:
            return nil
        }
    }
}

/// 「新しいメモ」の要求。コールドスタートでは URL を受けた時点で地図がまだ無いので、
/// 地図側が出てきたときに取り出せるよう、通知とは別に 1 回だけ覚えておく。
@MainActor
enum NewMemoRequest {
    private(set) static var isPending = false
    /// 設定・見守りの画面（`ContentView` が出すもの）が開いている間は true。閉じてから処理する。
    static var containerBlocked = false

    static func post() {
        isPending = true
        NotificationCenter.default.post(name: .startNewGeoMemo, object: nil)
    }

    /// 要求があれば true を返して消す。
    static func consume() -> Bool {
        defer { isPending = false }
        return isPending
    }
}

extension Notification.Name {
    static let startNewGeoMemo = Notification.Name("startNewGeoMemo")
}

import Foundation

/// 無料版のメモ数の上限。iPhone の追加ボタンと Watch のクイック追加で同じ判定を使う。
nonisolated enum MemoLimitPolicy {
    nonisolated static let freeMemoLimit = 5

    /// これ以上メモを作れないか。Pro なら上限なし。`currentCount` は完了済みを含む全メモ数。
    nonisolated static func isAtLimit(currentCount: Int, isPro: Bool) -> Bool {
        !isPro && currentCount >= freeMemoLimit
    }
}

import Foundation

/// 無料版のメモ数の上限。iPhone の追加ボタンの判定。
/// Watch のクイック追加には使わない（Watch は Pro かどうかを知る手段がなく、Pro の人まで制限してしまうため。
/// Pro 状態の同期は別 PR）。
nonisolated enum MemoLimitPolicy {
    nonisolated static let freeMemoLimit = 5

    /// これ以上メモを作れないか。Pro なら上限なし。`currentCount` は完了済みを含む全メモ数。
    nonisolated static func isAtLimit(currentCount: Int, isPro: Bool) -> Bool {
        !isPro && currentCount >= freeMemoLimit
    }
}

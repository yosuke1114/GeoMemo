import Foundation

/// Live Activity をどれだけ残し、どれを終え、何をするかの判断（純粋な関数。テスト対象）。
///
/// `LiveActivityManager` は、開始・件数の更新・到着などの更新のたびに、システムに残っている Activity の一覧と
/// 自分が覚えている状態からこれを作り、そのとおりに動く。
/// - 引き継ぎ：前回の起動で始めた Activity は `currentActivity`（プロセスの中の変数）から消えるので、一覧から 1 つ選んで引き継ぐ。
///   今の Activity が生きていればそれを優先する。余分なものは終える（起動のたびに増えないように）。
/// - 終了を頼んだもの（`endingIDs`）は、まだ一覧に生きて見えていても候補にしない（終わる途中のものを引き継がない）。
/// - ユーザーがロック画面で消した（または許可の確認で「許可しない」を選んだ）ときは、そのプロセスの間は出し直さない。
nonisolated struct LiveActivityPlan: Equatable {
    enum Action: Equatable {
        /// 何もしない（件数を渡されていない更新・0 件・ユーザーが消した）
        case none
        /// 残した Activity の件数を更新する
        case update
        /// 新しく始める
        case request
    }

    /// システムに残っている Activity。`isAlive` は終わっていない（`.ended` / `.dismissed` でない）。
    struct Existing: Equatable {
        var id: String
        var isAlive: Bool
    }

    /// 引き継ぐ（残す）Activity。
    var keepID: String?
    /// 終える Activity。
    var endIDs: [String]
    var action: Action

    /// - Parameters:
    ///   - count: 監視するメモの数。nil は件数を変えない更新（到着・接近・ルート）で、引き継ぎだけをする。
    ///   - userDismissed: このプロセスの間にユーザーが消した。
    static func make(existing: [Existing], currentID: String?, count: Int?,
                     endingIDs: Set<String>, userDismissed: Bool) -> LiveActivityPlan {
        let candidates = existing.filter { $0.isAlive && !endingIDs.contains($0.id) }
        if let count, count <= 0 {
            return LiveActivityPlan(keepID: nil, endIDs: candidates.map(\.id), action: .none)
        }
        let keep = candidates.first { $0.id == currentID } ?? candidates.first
        let endIDs = candidates.filter { $0.id != keep?.id }.map(\.id)
        let action: Action
        if count == nil {
            action = .none
        } else if keep != nil {
            action = .update
        } else {
            action = userDismissed ? .none : .request
        }
        return LiveActivityPlan(keepID: keep?.id, endIDs: endIDs, action: action)
    }
}

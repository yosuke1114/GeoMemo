import Testing
@testable import geomemo

// Live Activity の引き継ぎ・終了・開始の判断のテスト。ActivityKit には依存しない。

private typealias E = LiveActivityPlan.Existing

private func plan(_ existing: [E], current: String? = nil, count: Int?, ending: Set<String> = [],
                  dismissed: Bool = false) -> LiveActivityPlan {
    LiveActivityPlan.make(existing: existing, currentID: current, count: count,
                          endingIDs: ending, userDismissed: dismissed)
}

@Suite("LiveActivityPlan")
struct LiveActivityPlanTests {
    // MARK: 開始

    @Test func 何も無ければ始める() {
        #expect(plan([], count: 3) == LiveActivityPlan(keepID: nil, endIDs: [], action: .request))
    }

    @Test func 前の起動のものを引き継いで件数を更新する() {
        #expect(plan([E(id: "a", isAlive: true)], count: 3)
                == LiveActivityPlan(keepID: "a", endIDs: [], action: .update))
    }

    @Test func 余分なものは終える_今のものを優先して残す() {
        let existing = [E(id: "a", isAlive: true), E(id: "b", isAlive: true), E(id: "c", isAlive: true)]
        #expect(plan(existing, current: "b", count: 2)
                == LiveActivityPlan(keepID: "b", endIDs: ["a", "c"], action: .update))
        // 今のものが無ければ先頭を残す
        #expect(plan(existing, count: 2)
                == LiveActivityPlan(keepID: "a", endIDs: ["b", "c"], action: .update))
    }

    @Test func 終わったものは候補にも終了の対象にもしない() {
        let existing = [E(id: "a", isAlive: false), E(id: "b", isAlive: true)]
        #expect(plan(existing, current: "a", count: 1)
                == LiveActivityPlan(keepID: "b", endIDs: [], action: .update))
        #expect(plan([E(id: "a", isAlive: false)], count: 1)
                == LiveActivityPlan(keepID: nil, endIDs: [], action: .request))
    }

    // MARK: 終了中（中3）

    @Test func 終了を頼んだものは引き継がない() {
        let existing = [E(id: "a", isAlive: true), E(id: "b", isAlive: true)]
        #expect(plan(existing, current: "a", count: 2, ending: ["a"])
                == LiveActivityPlan(keepID: "b", endIDs: [], action: .update))
        // すべて終了中なら新しく始める（二重に終了を頼まない）
        #expect(plan(existing, count: 2, ending: ["a", "b"])
                == LiveActivityPlan(keepID: nil, endIDs: [], action: .request))
    }

    // MARK: ユーザーが消した（中4）

    @Test func ユーザーが消したら出し直さない() {
        #expect(plan([], count: 3, dismissed: true)
                == LiveActivityPlan(keepID: nil, endIDs: [], action: .none))
        #expect(plan([E(id: "a", isAlive: false)], current: "a", count: 3, dismissed: true)
                == LiveActivityPlan(keepID: nil, endIDs: [], action: .none))
    }

    @Test func ユーザーが消した後でも生きているものがあれば件数は更新する() {
        #expect(plan([E(id: "a", isAlive: true)], count: 3, dismissed: true)
                == LiveActivityPlan(keepID: "a", endIDs: [], action: .update))
    }

    // MARK: 0 件（低7）

    @Test func 件数が0なら生きているものをすべて終える() {
        let existing = [E(id: "a", isAlive: true), E(id: "b", isAlive: false), E(id: "c", isAlive: true)]
        #expect(plan(existing, current: "a", count: 0)
                == LiveActivityPlan(keepID: nil, endIDs: ["a", "c"], action: .none))
        #expect(plan(existing, count: 0, ending: ["a"])
                == LiveActivityPlan(keepID: nil, endIDs: ["c"], action: .none))
        #expect(plan([], count: 0) == LiveActivityPlan(keepID: nil, endIDs: [], action: .none))
    }

    // MARK: 件数を変えない更新（到着・接近・ルート、中1）

    @Test func 件数なしの更新は引き継ぎだけで始めない() {
        #expect(plan([], count: nil) == LiveActivityPlan(keepID: nil, endIDs: [], action: .none))
        let existing = [E(id: "a", isAlive: true), E(id: "b", isAlive: true)]
        #expect(plan(existing, count: nil)
                == LiveActivityPlan(keepID: "a", endIDs: ["b"], action: .none))
        #expect(plan(existing, current: "b", count: nil, dismissed: true)
                == LiveActivityPlan(keepID: "b", endIDs: ["a"], action: .none))
    }
}

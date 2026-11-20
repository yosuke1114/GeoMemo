import Testing
@testable import geomemo

struct MemoLimitPolicyTests {
    @Test func 無料版は上限でメモを作れない() {
        #expect(!MemoLimitPolicy.isAtLimit(currentCount: MemoLimitPolicy.freeMemoLimit - 1, isPro: false))
        #expect(MemoLimitPolicy.isAtLimit(currentCount: MemoLimitPolicy.freeMemoLimit, isPro: false))
    }

    @Test func Proは上限なし() {
        #expect(!MemoLimitPolicy.isAtLimit(currentCount: 100, isPro: true))
    }
}

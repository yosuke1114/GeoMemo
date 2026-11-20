import Testing
import Foundation
@testable import geomemo

// MARK: - 範囲 (半径) の丸め・制限

@Suite("RadiusPolicy")
struct RadiusPolicyTests {
    @Test("下限・上限・既定値は設定画面の候補 (50M〜1KM, 既定 100M) と同じ")
    func constants() {
        #expect(RadiusPolicy.minimum == 50)
        #expect(RadiusPolicy.maximum == 1000)
        #expect(RadiusPolicy.defaultValue == 100)
        #expect(RadiusPolicy.presets == [50, 100, 500, 1000])
        #expect(PlaceMemoDraft.defaultRadius == RadiusPolicy.defaultValue)
    }

    @Test("clamp は下限〜上限に収め、数値でない値は既定値にする")
    func clamp() {
        #expect(RadiusPolicy.clamp(10) == 50)
        #expect(RadiusPolicy.clamp(75) == 75)
        #expect(RadiusPolicy.clamp(5000) == 1000)
        #expect(RadiusPolicy.clamp(.nan) == 100)
        #expect(RadiusPolicy.clamp(.infinity) == 100)
    }

    @Test("snapped は 10m 刻みに丸めてから収める")
    func snapped() {
        #expect(RadiusPolicy.snapped(104) == 100)
        #expect(RadiusPolicy.snapped(105) == 110)
        #expect(RadiusPolicy.snapped(52) == 50)
        #expect(RadiusPolicy.snapped(20) == 50)
        #expect(RadiusPolicy.snapped(1234) == 1000)
        #expect(RadiusPolicy.snapped(.nan) == 100)
    }

    @Test("開いた時点の値に合わせて上限を広げる")
    func ceiling() {
        #expect(RadiusPolicy.ceiling(forOriginal: 100) == 1000)
        #expect(RadiusPolicy.ceiling(forOriginal: 1500) == 1500)
        #expect(RadiusPolicy.ceiling(forOriginal: .nan) == 1000)
        #expect(RadiusPolicy.sliderRange(ceiling: 1000) == 50...1000)
        #expect(RadiusPolicy.sliderRange(ceiling: 1500) == 50...1500)
    }

    @Test("1000m 超で保存された値は、触ったあとも元の値まで戻せる")
    func snappedWithCeiling() {
        #expect(RadiusPolicy.snapped(1500, ceiling: 1500) == 1500)
        #expect(RadiusPolicy.snapped(1505, ceiling: 1505) == 1505)
        #expect(RadiusPolicy.snapped(1400, ceiling: 1500) == 1400)
        #expect(RadiusPolicy.snapped(2000, ceiling: 1500) == 1500)
        #expect(RadiusPolicy.snapped(1500) == 1000) // 上限を渡さなければ従来どおり
        // 上限未満に下げてから元に戻す
        let down = RadiusPolicy.applyingSlider(900, to: 1500, ceiling: 1500)
        #expect(down == 900)
        #expect(RadiusPolicy.applyingSlider(1500, to: down, ceiling: 1500) == 1500)
    }

    @Test("刻みに乗らない値・50m 未満の値は、スライダーが同じ値や丸めた値を返しても変わらない")
    func untouchedValuesStay() {
        for original in [45.0, 52, 77, 104, 1234] {
            let ceiling = RadiusPolicy.ceiling(forOriginal: original)
            // 表示のために丸めた値・範囲に収めた値を書き戻されても、現在値を保つ
            let echoes = [original, RadiusPolicy.snapped(original, ceiling: ceiling),
                          min(max(original, 50), ceiling)]
            for echo in echoes {
                #expect(RadiusPolicy.applyingSlider(echo, to: original, ceiling: ceiling) == original)
            }
        }
    }

    @Test("実際に動かしたら (刻みの半分を超えたら) 反映する")
    func movedValuesApply() {
        #expect(RadiusPolicy.applyingSlider(110, to: 100, ceiling: 1000) == 110)
        #expect(RadiusPolicy.applyingSlider(1000, to: 100, ceiling: 1000) == 1000)
        #expect(RadiusPolicy.applyingSlider(0, to: 100, ceiling: 1000) == 50)
        #expect(RadiusPolicy.applyingSlider(.nan, to: 100, ceiling: 1000) == 100)
    }

    @Test("VoiceOver の増減は 50m 単位で、下限・上限に収める")
    func accessibilityAdjust() {
        #expect(RadiusPolicy.adjusted(100, increment: true, ceiling: 1000) == 150)
        #expect(RadiusPolicy.adjusted(100, increment: false, ceiling: 1000) == 50)
        #expect(RadiusPolicy.adjusted(50, increment: false, ceiling: 1000) == 50)
        #expect(RadiusPolicy.adjusted(1000, increment: true, ceiling: 1000) == 1000)
        #expect(RadiusPolicy.adjusted(1000, increment: true, ceiling: 1500) == 1050)
        #expect(RadiusPolicy.adjusted(1500, increment: true, ceiling: 1500) == 1500)
    }

    @Test("100m 未満は建物の中で反応しにくい注意を出す")
    func indoorWarning() {
        #expect(RadiusPolicy.isTooSmallForIndoors(50))
        #expect(RadiusPolicy.isTooSmallForIndoors(99))
        #expect(!RadiusPolicy.isTooSmallForIndoors(100))
        #expect(!RadiusPolicy.isTooSmallForIndoors(500))
    }

    @Test("地図の幅は円が 8.5 割以内に収まる最小の段で、範囲に対して単調")
    func mapSpan() {
        #expect(RadiusPolicy.mapSpanMeters(for: 50) == 260)
        #expect(RadiusPolicy.mapSpanMeters(for: 100) == 260)
        #expect(RadiusPolicy.mapSpanMeters(for: 110) == 260)
        #expect(RadiusPolicy.mapSpanMeters(for: 111) == 520)
        #expect(RadiusPolicy.mapSpanMeters(for: 500) == 2080)
        #expect(RadiusPolicy.mapSpanMeters(for: 1000) == 4160)
        #expect(RadiusPolicy.mapSpanMeters(for: 100000) == 4160)
        var last = 0.0
        for r in stride(from: 50.0, through: 1500, by: 10) {
            let span = RadiusPolicy.mapSpanMeters(for: r)
            #expect(span >= last)
            #expect(r * 2 <= span * RadiusPolicy.mapFillRatio || span == 4160)
            last = span
        }
    }

    @Test("段の境目は、既定値と候補 (50/100/500/1000) から 5% 以上離れている")
    func mapSpanBoundariesAvoidPresets() {
        let boundaries = RadiusPolicy.mapSpanSteps.map { $0 * RadiusPolicy.mapFillRatio / 2 }
        for value in RadiusPolicy.presets + [RadiusPolicy.defaultValue] {
            for b in boundaries { #expect(abs(b - value) / value > 0.05) }
        }
    }

    @Test("表記は設定画面と同じ (150M / 1KM)")
    func label() {
        #expect(RadiusPolicy.label(150) == "150M")
        #expect(RadiusPolicy.label(1000) == "1KM")
        #expect(RadiusPolicy.label(1200) == "1.2KM")
        #expect(RadiusPolicy.label(2000) == "2KM")
    }
}

// MARK: - 「詳細」の要約

@Suite("MemoAdvancedSummary")
struct MemoAdvancedSummaryTests {
    @Test("既定の状態では何も出さない")
    func empty() {
        #expect(MemoAdvancedSummary.items(for: MemoAdvancedState()).isEmpty)
        #expect(MemoAdvancedSummary.text(for: []) == "")
    }

    @Test("空白だけのメモは設定済みにしない")
    func blankNote() {
        #expect(MemoAdvancedSummary.items(for: MemoAdvancedState(note: " \n ")).isEmpty)
        #expect(MemoAdvancedSummary.items(for: MemoAdvancedState(note: "牛乳")) == [.note])
    }

    @Test("リストモードでは、メモではなく項目数を数える")
    func listMode() {
        let s = MemoAdvancedState(note: "古いメモ", isListMode: true, listItemCount: 3)
        #expect(MemoAdvancedSummary.items(for: s) == [.checklist(count: 3)])
        #expect(MemoAdvancedSummary.items(for: MemoAdvancedState(isListMode: true)).isEmpty)
    }

    @Test("条件・滞在・遅延・通りかかりを画面の並びで返す")
    func ordering() {
        let s = MemoAdvancedState(
            hasPhoto: true, colorIndex: 2, tagCount: 2,
            hasDeadline: true, timeWindow: (600, 1200), activeDayCount: 5,
            dwellMinutes: 5, exitDelayMinutes: 15, notifyOnPass: true)
        #expect(MemoAdvancedSummary.items(for: s) == [
            .photo, .color, .tags(count: 2),
            .dwell(minutes: 5), .exitDelay(minutes: 15), .passThrough,
            .expiry, .timeWindow(startMinutes: 600, endMinutes: 1200), .days(count: 5),
        ])
    }

    @Test("到着・退出をオフにした側の滞在・遅延は、保存で効かないので数えない")
    func hiddenDelays() {
        let s = MemoAdvancedState(notifyOnEntry: false, notifyOnExit: false,
                                  dwellMinutes: 5, exitDelayMinutes: 15)
        #expect(MemoAdvancedSummary.items(for: s).isEmpty)
    }

    @Test("ルートのときは滞在・遅延・通りかかりを数えず、ルートを出す")
    func route() {
        let s = MemoAdvancedState(isRouteTrigger: true, waypointCount: 3,
                                  dwellMinutes: 5, exitDelayMinutes: 5, notifyOnPass: true)
        #expect(MemoAdvancedSummary.items(for: s) == [.route(waypoints: 3)])
    }

    @Test("時刻は H:MM、範囲外の値でも落ちない")
    func clock() {
        #expect(MemoAdvancedItem.clock(600) == "10:00")
        #expect(MemoAdvancedItem.clock(65) == "1:05")
        #expect(MemoAdvancedItem.clock(-5) == "0:00")
        #expect(MemoAdvancedItem.clock(5000) == "23:59")
    }

    @Test("要約の文字は項目ごとに空でない")
    func texts() {
        let all: [MemoAdvancedItem] = [.note, .checklist(count: 1), .photo, .color, .tags(count: 1), .expiry,
            .timeWindow(startMinutes: 0, endMinutes: 60), .days(count: 2), .route(waypoints: 2),
            .dwell(minutes: 5), .exitDelay(minutes: 5), .passThrough]
        for item in all { #expect(!item.text.isEmpty) }
        #expect(!MemoAdvancedSummary.text(for: all).isEmpty)
    }
}

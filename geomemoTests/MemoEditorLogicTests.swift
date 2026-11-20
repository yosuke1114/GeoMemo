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

    @Test("すでに上限を超えて保存された値でも、スライダーの範囲に入る")
    func sliderRange() {
        #expect(RadiusPolicy.sliderRange(including: 100) == 50...1000)
        #expect(RadiusPolicy.sliderRange(including: 1500) == 50...1500)
        #expect(RadiusPolicy.sliderRange(including: .nan) == 50...1000)
    }

    @Test("100m 未満は建物の中で反応しにくい注意を出す")
    func indoorWarning() {
        #expect(RadiusPolicy.isTooSmallForIndoors(50))
        #expect(RadiusPolicy.isTooSmallForIndoors(99))
        #expect(!RadiusPolicy.isTooSmallForIndoors(100))
        #expect(!RadiusPolicy.isTooSmallForIndoors(500))
    }

    @Test("地図の幅は円が 8 割以内に収まる最小の段で、範囲に対して単調")
    func mapSpan() {
        #expect(RadiusPolicy.mapSpanMeters(for: 50) == 250)
        #expect(RadiusPolicy.mapSpanMeters(for: 100) == 250)
        #expect(RadiusPolicy.mapSpanMeters(for: 101) == 500)
        #expect(RadiusPolicy.mapSpanMeters(for: 800) == 2000)
        #expect(RadiusPolicy.mapSpanMeters(for: 801) == 4000)
        #expect(RadiusPolicy.mapSpanMeters(for: 1000) == 4000)
        #expect(RadiusPolicy.mapSpanMeters(for: 100000) == 4000)
        var last = 0.0
        for r in stride(from: 50.0, through: 1500, by: 10) {
            let span = RadiusPolicy.mapSpanMeters(for: r)
            #expect(span >= last)
            #expect(r * 2 <= span * 0.8 || span == 4000)
            last = span
        }
    }

    @Test("表記は従来の詳細画面と同じ (150M / 1.0KM)")
    func label() {
        #expect(RadiusPolicy.label(150) == "150M")
        #expect(RadiusPolicy.label(1000) == "1.0KM")
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

import Testing
import Foundation
import SwiftUI
import UIKit
@testable import geomemo

// MARK: - リストの表示状態 (Q-3)

@Suite("ListContentState")
struct ListContentStateTests {
    @Test("メモ 0 件・受信 0 件 → 空状態")
    func bothEmpty() {
        #expect(ListContentState.resolve(ownMemoCount: 0, receivedCount: 0) == .empty)
    }

    @Test("メモ 0 件・受信 1 件以上 → 受信した依頼だけを出す")
    func receivedOnly() {
        #expect(ListContentState.resolve(ownMemoCount: 0, receivedCount: 1) == .receivedOnly)
        #expect(ListContentState.resolve(ownMemoCount: 0, receivedCount: 5) == .receivedOnly)
    }

    @Test("メモがあれば受信の有無にかかわらず通常表示")
    func withMemos() {
        #expect(ListContentState.resolve(ownMemoCount: 1, receivedCount: 0) == .memos)
        #expect(ListContentState.resolve(ownMemoCount: 3, receivedCount: 2) == .memos)
    }
}

// MARK: - 時刻の日付 (Q-6)

@Suite("RelativeDay / dayAndTimeText")
struct RelativeDayTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test("同じ日は今日、日付をまたぐと昨日・明日")
    func classification() {
        let now = date(2026, 11, 20, 0, 5)
        #expect(RelativeDay.of(date(2026, 11, 20, 23, 59), now: now, calendar: calendar) == .today)
        #expect(RelativeDay.of(date(2026, 11, 19, 23, 59), now: now, calendar: calendar) == .yesterday)
        #expect(RelativeDay.of(date(2026, 11, 21, 0, 0), now: now, calendar: calendar) == .tomorrow)
        #expect(RelativeDay.of(date(2026, 11, 18, 12), now: now, calendar: calendar) == .other)
        #expect(RelativeDay.of(date(2026, 11, 22, 12), now: now, calendar: calendar) == .other)
    }

    @Test("月をまたぐ昨日")
    func acrossMonth() {
        let now = date(2026, 12, 1, 9)
        #expect(RelativeDay.of(date(2026, 11, 30, 22), now: now, calendar: calendar) == .yesterday)
    }

    @Test("今日の時刻テキストに時刻が含まれる")
    func textContainsTime() {
        let text = dayAndTimeText(Date(), now: Date())
        #expect(text.isEmpty == false)
    }
}

// MARK: - 地図ピンの VoiceOver ラベル (Q-2)

@Suite("mapPinAccessibilityLabel")
struct MapPinLabelTests {
    @Test("タイトルと場所名を読み上げる")
    func titleAndLocation() {
        #expect(mapPinAccessibilityLabel(title: "牛乳", locationName: "スーパー", isDone: false) == "牛乳、スーパー")
    }

    @Test("場所名が空ならタイトルだけ")
    func noLocation() {
        #expect(mapPinAccessibilityLabel(title: "牛乳", locationName: "", isDone: false) == "牛乳")
    }

    @Test("完了済みなら末尾に付く")
    func done() {
        let label = mapPinAccessibilityLabel(title: "牛乳", locationName: "スーパー", isDone: true)
        #expect(label.hasPrefix("牛乳、スーパー、"))
        #expect(label.count > "牛乳、スーパー、".count)
    }
}

// MARK: - コントラスト (Q-14)

@MainActor
@Suite("Brand contrast")
struct BrandContrastTests {
    private func resolved(_ color: Color, dark: Bool) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
    }

    private func luminance(_ c: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func f(_ v: CGFloat) -> Double {
            let x = Double(v)
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
    }

    /// 不透明度のある前景は背景と混ぜてから比べる。
    private func blend(_ fg: UIColor, over bg: UIColor) -> UIColor {
        var fr: CGFloat = 0, fg_: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bg_: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        fg.getRed(&fr, green: &fg_, blue: &fb, alpha: &fa)
        bg.getRed(&br, green: &bg_, blue: &bb, alpha: &ba)
        return UIColor(red: fr * fa + br * (1 - fa), green: fg_ * fa + bg_ * (1 - fa),
                       blue: fb * fa + bb * (1 - fa), alpha: 1)
    }

    private func ratio(_ fg: Color, _ bg: Color, dark: Bool) -> Double {
        let b = resolved(bg, dark: dark)
        let f = blend(resolved(fg, dark: dark), over: b)
        let l1 = luminance(f), l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test("本文・補助文字は背景に対して 4.5:1 以上", arguments: [false, true])
    func textColors(dark: Bool) {
        for fg in [Brand.primaryText, Brand.secondaryText, Brand.tertiaryText, Brand.warning] {
            #expect(ratio(fg, Brand.background, dark: dark) >= 4.5)
            #expect(ratio(fg, Brand.surface, dark: dark) >= 4.5)
        }
    }

    @Test("青地の文字・アイコンは 4.5:1 以上", arguments: [false, true])
    func onAccent(dark: Bool) {
        #expect(ratio(Brand.onAccent, Brand.blue, dark: dark) >= 4.5)
    }

    @Test("琥珀色のピンは白地で 3:1 以上")
    func amberPin() {
        #expect(ratio(MemoColor.amber.color, Color.white, dark: false) >= 3.0)
    }
}

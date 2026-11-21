import Testing
import Foundation
@testable import geomemo

// 文章でメモを作る (L-4) の純粋なロジックのテスト。端末内モデルは呼ばない（偽の parser / searcher を使う）。

private nonisolated func calendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}
/// 2026-11-21 (土) 12:00 JST
private nonisolated func now() -> Date {
    calendar().date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 12))!
}
private func place(_ name: String, sub: String = "", icon: String = "mappin.fill",
                   lat: Double = 35.68, lon: Double = 139.76) -> PlaceCandidate {
    PlaceCandidate(id: UUID(), name: name, subtitle: sub, latitude: lat, longitude: lon, iconName: icon)
}

@Suite("NLInput.sanitize")
struct NLInputTests {
    @Test("前後の空白・改行を落とし、連続する空白を 1 つにする")
    func trims() {
        #expect(NLInput.sanitize("  駅に着いたら\n牛乳を   買う\t") == "駅に着いたら 牛乳を 買う")
        #expect(NLInput.sanitize("駅に着いたら　牛乳") == "駅に着いたら 牛乳")
    }
    @Test("空・空白だけは nil")
    func empty() {
        #expect(NLInput.sanitize("") == nil)
        #expect(NLInput.sanitize(" \n\t　 ") == nil)
    }
    @Test("制御文字・方向制御・ゼロ幅の書式文字を落とす")
    func controls() {
        #expect(NLInput.sanitize("a\u{0007}b") == "ab")
        #expect(NLInput.sanitize("a\u{202E}b\u{200B}c") == "abc")
    }
    @Test("絵文字の結合 (ZWJ)・ZWNJ・旗のタグ文字は残す")
    func keepsJoiners() {
        let family = "👨\u{200D}👩\u{200D}👧"
        #expect(NLInput.sanitize("家族 \(family)") == "家族 \(family)")
        let scotland = "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
        #expect(NLInput.sanitize(scotland) == scotland)
        #expect(NLInput.sanitize("می\u{200C}خواهم") == "می\u{200C}خواهم")
        #expect(NLInput.sanitize("a\u{FEFF}b\u{2060}c\u{2066}d\u{2069}e\u{200E}f") == "abcdef")
    }

    @Test("地図に送る検索語は 50 字までに切る")
    func searchQueryCap() {
        let long = String(repeating: "あ", count: 120)
        #expect(NLInput.searchQuery(long)?.count == NLInput.maxSearchQueryLength)
        #expect(NLInput.searchQuery("  ドラッグストア \n") == "ドラッグストア")
        #expect(NLInput.searchQuery("   ") == nil)
    }

    @Test("長すぎる入力は上限で切る")
    func caps() {
        let long = String(repeating: "あ", count: 500)
        #expect(NLInput.sanitize(long)?.count == NLInput.maxLength)
        let exact = String(repeating: "a", count: NLInput.maxLength)
        #expect(NLInput.sanitize(exact) == exact)
    }
}

@Suite("NLMemoNormalizer")
struct NLMemoNormalizerTests {
    @Test("通知の種別")
    func trigger() throws {
        let a = try #require(NLMemoNormalizer.trigger("arrive"))
        #expect(a.entry && !a.exit)
        let l = try #require(NLMemoNormalizer.trigger(" Leave "))
        #expect(!l.entry && l.exit)
        let b = try #require(NLMemoNormalizer.trigger("both"))
        #expect(b.entry && b.exit)
        #expect(NLMemoNormalizer.trigger("unspecified") == nil)
        #expect(NLMemoNormalizer.trigger("") == nil)
        #expect(NLMemoNormalizer.trigger("whenever") == nil)
    }

    @Test("時刻の読み取り")
    func minutes() {
        #expect(NLMemoNormalizer.minutes(from: "17:00") == 1020)
        #expect(NLMemoNormalizer.minutes(from: "9:05") == 545)
        #expect(NLMemoNormalizer.minutes(from: "17") == 1020)
        #expect(NLMemoNormalizer.minutes(from: "17時") == 1020)
        #expect(NLMemoNormalizer.minutes(from: "７：３０") == 450)
        #expect(NLMemoNormalizer.minutes(from: "5:30pm") == 1050)
        #expect(NLMemoNormalizer.minutes(from: "12am") == 0)
        #expect(NLMemoNormalizer.minutes(from: "12pm") == 720)
        #expect(NLMemoNormalizer.minutes(from: "24:00") == 1439)
        #expect(NLMemoNormalizer.minutes(from: "25:00") == nil)
        #expect(NLMemoNormalizer.minutes(from: "12:60") == nil)
        #expect(NLMemoNormalizer.minutes(from: "13pm") == nil)
        #expect(NLMemoNormalizer.minutes(from: "evening") == nil)
        #expect(NLMemoNormalizer.minutes(from: "") == nil)
        #expect(NLMemoNormalizer.minutes(from: "-3:00") == nil)
        #expect(NLMemoNormalizer.minutes(from: "17:xx") == nil)     // 分が読めない
        #expect(NLMemoNormalizer.minutes(from: "17時30分") == 1050)
    }

    @Test("時間帯: 始まり < 終わり だけ通す。片方だけ・またぐ指定・長さ 0 は nil")
    func timeWindow() {
        #expect(NLMemoNormalizer.timeWindow(start: "16:00", end: "19:00") == NLTimeWindow(startMinutes: 960, endMinutes: 1140))
        #expect(NLMemoNormalizer.timeWindow(start: "16:00", end: nil) == nil)
        #expect(NLMemoNormalizer.timeWindow(start: nil, end: "19:00") == nil)
        #expect(NLMemoNormalizer.timeWindow(start: "22:00", end: "06:00") == nil)
        #expect(NLMemoNormalizer.timeWindow(start: "10:00", end: "10:00") == nil)
        #expect(NLMemoNormalizer.timeWindow(start: "xx", end: "19:00") == nil)
        #expect(NLMemoNormalizer.timeWindow(start: "19:00", end: "24:00") == NLTimeWindow(startMinutes: 1140, endMinutes: 1439))
    }

    @Test("曜日: 英語・日本語・まとまりの語。昇順・重複なし")
    func days() {
        #expect(NLMemoNormalizer.activeDays(["mon", "thu"]) == [1, 4])
        #expect(NLMemoNormalizer.activeDays(["Thursday", "Monday", "mon"]) == [1, 4])
        #expect(NLMemoNormalizer.activeDays(["weekdays"]) == [1, 2, 3, 4, 5])
        #expect(NLMemoNormalizer.activeDays(["平日"]) == [1, 2, 3, 4, 5])
        #expect(NLMemoNormalizer.activeDays(["weekends"]) == [0, 6])
        #expect(NLMemoNormalizer.activeDays(["土日"]) == [0, 6])
        #expect(NLMemoNormalizer.activeDays(["月曜日", "木曜"]) == [1, 4])
        #expect(NLMemoNormalizer.activeDays(["月水金"]) == [1, 3, 5])
        #expect(NLMemoNormalizer.activeDays(["日"]) == [0])
    }

    @Test("曜日: 毎日・空・読めない語は nil（毎日と同じ）")
    func daysNil() {
        #expect(NLMemoNormalizer.activeDays([]) == nil)
        #expect(NLMemoNormalizer.activeDays(["毎日"]) == nil)
        #expect(NLMemoNormalizer.activeDays(["everyday"]) == nil)
        #expect(NLMemoNormalizer.activeDays(["weekdays", "weekends"]) == nil)
        #expect(NLMemoNormalizer.activeDays(["blursday", "foo"]) == nil)
        // "every" は完全一致だけ（everyone や every other week は毎日ではない）
        #expect(NLMemoNormalizer.activeDays(["every other week"]) == nil)
        #expect(NLMemoNormalizer.parseDays(["every other week"]).everyDay == false)
        #expect(NLMemoNormalizer.parseDays(["every day"]).everyDay == true)
        #expect(NLMemoNormalizer.activeDays([""]) == nil)
    }

    @Test("期限: その日の 23:59。過去・存在しない日・遠すぎる日・読めない値は nil")
    func deadline() throws {
        let cal = calendar()
        let d = try #require(NLMemoNormalizer.deadline("2026-11-27", now: now(), calendar: cal))
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        #expect(c.year == 2026 && c.month == 11 && c.day == 27 && c.hour == 23 && c.minute == 59)
        #expect(NLMemoNormalizer.deadline("2026-11-21", now: now(), calendar: cal) != nil)
        #expect(NLMemoNormalizer.deadline("2026-11-20", now: now(), calendar: cal) == nil)
        #expect(NLMemoNormalizer.deadline("2026-02-30", now: now(), calendar: cal) == nil)
        #expect(NLMemoNormalizer.deadline("2030-01-01", now: now(), calendar: cal) == nil)
        #expect(NLMemoNormalizer.deadline("来週の金曜", now: now(), calendar: cal) == nil)
        #expect(NLMemoNormalizer.deadline("", now: now(), calendar: cal) == nil)
        #expect(NLMemoNormalizer.deadline(nil, now: now(), calendar: cal) == nil)
        #expect(NLMemoNormalizer.deadline("2026-13-01", now: now(), calendar: cal) == nil)
    }

    @Test("下書き: 値が全部そろっている")
    func fullDraft() {
        let raw = NLMemoRaw(title: " 洗剤を買う ", placeQuery: "ドラッグストア", trigger: "arrive",
                            timeStart: "16:00", timeEnd: "19:00", days: ["weekdays"], deadline: "2026-12-01")
        let d = NLMemoNormalizer.draft(from: raw, originalText: "平日の夕方…", now: now(), calendar: calendar())
        #expect(d.title == "洗剤を買う")
        #expect(d.placeQuery == "ドラッグストア")
        #expect(d.notifyOnEntry == true && d.notifyOnExit == false)
        #expect(d.timeWindow == NLTimeWindow(startMinutes: 960, endMinutes: 1140))
        #expect(d.activeDays == [1, 2, 3, 4, 5])
        #expect(d.deadline != nil)
    }

    @Test("下書き: 題が空なら入力文を題にする。unspecified は通知を触らない")
    func emptyTitle() {
        let raw = NLMemoRaw(title: "   ", placeQuery: "", trigger: "unspecified")
        let d = NLMemoNormalizer.draft(from: raw, originalText: "牛乳を買う", now: now(), calendar: calendar())
        #expect(d.title == "牛乳を買う")
        #expect(d.placeQuery == nil)
        #expect(d.notifyOnEntry == nil && d.notifyOnExit == nil)
        #expect(d.timeWindow == nil && d.activeDays == nil && d.deadline == nil)
    }

    @Test("下書き: 題が長すぎれば切る")
    func longTitle() {
        let raw = NLMemoRaw(title: String(repeating: "あ", count: 300))
        let d = NLMemoNormalizer.draft(from: raw, originalText: "x", now: now(), calendar: calendar())
        #expect(d.title.count == NLMemoNormalizer.maxTitleLength)
    }

    @Test("下書き: 壊れた値（時刻・曜日・期限）は無視して、残りは通す")
    func garbage() {
        let raw = NLMemoRaw(title: "洗剤", placeQuery: "x", trigger: "??", timeStart: "yesterday", timeEnd: "tomorrow",
                            days: ["???"], deadline: "soon")
        let d = NLMemoNormalizer.draft(from: raw, originalText: "x", now: now(), calendar: calendar())
        #expect(d.title == "洗剤")
        #expect(d.timeWindow == nil && d.activeDays == nil && d.deadline == nil && d.notifyOnEntry == nil)
    }
}

@Suite("NLPlaceSelector")
struct NLPlaceSelectorTests {
    @Test("お気に入りで当たった場所が、地図の検索結果より先に来る")
    func favoritesFirst() {
        let home = place("自宅", icon: "house.fill", lat: 35.0, lon: 139.0)
        let shop = place("ドラッグストア A", lat: 35.1, lon: 139.1)
        let result = NLPlaceSelector.choose(query: "自宅", favorites: [home], searched: [shop], near: nil)
        #expect(result.map(\.place.name) == ["自宅", "ドラッグストア A"])
        #expect(result.map(\.source) == [.favorite, .search])
    }

    @Test("検索結果は現在地に近い順。同じ距離なら元の順")
    func nearestFirst() {
        let far = place("遠い", lat: 35.30, lon: 139.0)
        let near = place("近い", lat: 35.01, lon: 139.0)
        let mid = place("中間", lat: 35.10, lon: 139.0)
        let r = NLPlaceSelector.choose(query: "x", favorites: [], searched: [far, near, mid],
                                       near: NLPoint(latitude: 35.0, longitude: 139.0))
        #expect(r.map(\.place.name) == ["近い", "中間", "遠い"])
        let a = place("A", lat: 35.2, lon: 139.2), b = place("B", lat: 35.3, lon: 139.3)
        let ties = NLPlaceSelector.choose(query: "x", favorites: [], searched: [b, a], near: nil)
        #expect(ties.map(\.place.name) == ["B", "A"])
    }

    @Test("お気に入りと同じ場所・同じ名前の検索結果は省く")
    func dedupe() {
        let station = place("渋谷駅", lat: 35.6580, lon: 139.7016)
        let same = place("渋谷駅", lat: 35.6582, lon: 139.7018)
        let sameName = place("渋谷駅", lat: 35.6600, lon: 139.7016)
        let other = place("渋谷駅前郵便局", lat: 35.6590, lon: 139.7030)
        let r = NLPlaceSelector.choose(query: "渋谷駅", favorites: [station], searched: [same, sameName, other], near: nil)
        #expect(r.map(\.place.name) == ["渋谷駅", "渋谷駅前郵便局"])
    }

    @Test("座標が壊れている・名前が空の候補は除く")
    func invalid() {
        let r = NLPlaceSelector.choose(query: nil, favorites: [], searched: [
            place("原点", lat: 0, lon: 0),
            place("範囲外", lat: 95, lon: 10),
            place("非数", lat: .nan, lon: 10),
            place("  ", lat: 35, lon: 139),
            place("正常", lat: 35, lon: 139),
        ], near: nil)
        #expect(r.map(\.place.name) == ["正常"])
    }

    @Test("候補は最大 5 件")
    func limit() {
        let many = (0..<12).map { place("店\($0)", lat: 35 + Double($0) * 0.01, lon: 139) }
        #expect(NLPlaceSelector.choose(query: "店", favorites: [], searched: many, near: nil).count == NLPlaceSelector.maxCandidates)
    }

    @Test("お気に入りの語が当たらなければ、お気に入りは候補に入らない")
    func noFavoriteMatch() {
        let home = place("自宅", icon: "house.fill")
        #expect(NLPlaceSelector.choose(query: "ジム", favorites: [home], searched: [], near: nil).isEmpty)
    }

    @Test("2 点の距離")
    func distance() {
        let p = NLPoint(latitude: 35.0, longitude: 139.0)
        #expect(NLPlaceSelector.distance(p, p) == 0)
        let v = NLPlaceSelector.distance(p, NLPoint(latitude: 35.01, longitude: 139.0))
        #expect(abs(v - 1112) < 5)
    }
}

// MARK: - 偽のモデルと検索

private nonisolated struct FakeParser: NLMemoParsing {
    var result: Result<NLParseResult, Error>
    var delay: Duration = .zero
    func parse(text: String, today: Date, calendar: Calendar, favorites: [PlaceCandidate], near: NLPoint?) async throws -> NLParseResult {
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}
private nonisolated struct SomeModelError: Error {}

private nonisolated final class SearchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _queries: [String] = []
    nonisolated var queries: [String] { lock.withLock { _queries } }
    nonisolated func add(_ q: String) { lock.withLock { _queries.append(q) } }
}
private nonisolated struct FakeSearcher: NLPlaceSearching {
    var results: [PlaceCandidate] = []
    var log = SearchLog()
    func search(query: String, near: NLPoint?) async -> [PlaceCandidate] { log.add(query); return results }
}

@Suite("NLMemoComposer")
struct NLMemoComposerTests {
    @Test("読み取れたら下書きになり、お気に入りの場所が先頭の候補になる")
    func draft() async {
        let station = place("駅", icon: "train.side.front.car")
        let parser = FakeParser(result: .success(NLParseResult(raw: NLMemoRaw(title: "牛乳を買う", placeQuery: "駅", trigger: "arrive"))))
        let searcher = FakeSearcher()
        let outcome = await NLMemoComposer(parser: parser, searcher: searcher)
            .compose("駅に着いたら牛乳を買う", favorites: [station], near: nil, now: now(), calendar: calendar())
        guard case .draft(let d) = outcome else { Issue.record("draft ではない: \(outcome)"); return }
        #expect(d.title == "牛乳を買う")
        #expect(d.candidates.first?.place == station)
        #expect(d.candidates.first?.source == .favorite)
        #expect(searcher.log.queries.isEmpty)
    }

    @Test("お気に入りに無く、モデルがツールを使わなかったときは、自分で地図を引く")
    func fallbackSearch() async {
        let drug = place("ドラッグストア B", lat: 35.2, lon: 139.2)
        let parser = FakeParser(result: .success(NLParseResult(raw: NLMemoRaw(title: "洗剤", placeQuery: "ドラッグストア"))))
        let searcher = FakeSearcher(results: [drug])
        let outcome = await NLMemoComposer(parser: parser, searcher: searcher)
            .compose("ドラッグストアで洗剤", favorites: [], near: nil, now: now(), calendar: calendar())
        guard case .draft(let d) = outcome else { Issue.record("draft ではない"); return }
        #expect(searcher.log.queries == ["ドラッグストア"])
        #expect(d.candidates.map(\.place) == [drug])
        #expect(d.candidates.first?.source == .search)
    }

    @Test("モデルのツールが引いた検索結果があれば、重ねて地図を引かない")
    func toolResultsUsed() async {
        let fromTool = place("ツールの店", lat: 35.2, lon: 139.2)
        let parser = FakeParser(result: .success(NLParseResult(raw: NLMemoRaw(title: "洗剤", placeQuery: "ドラッグストア"),
                                                              searches: [NLSearchRecord(query: "ドラッグストア", places: [fromTool])])))
        let searcher = FakeSearcher(results: [place("別の店", lat: 36, lon: 140)])
        let outcome = await NLMemoComposer(parser: parser, searcher: searcher)
            .compose("ドラッグストアで洗剤", favorites: [], near: nil, now: now(), calendar: calendar())
        guard case .draft(let d) = outcome else { Issue.record("draft ではない"); return }
        #expect(searcher.log.queries.isEmpty)
        #expect(d.candidates.map(\.place) == [fromTool])
    }

    @Test("場所の語が空なら地図を引かず、候補なしの下書きになる")
    func noPlace() async {
        let parser = FakeParser(result: .success(NLParseResult(raw: NLMemoRaw(title: "牛乳を買う"))))
        let searcher = FakeSearcher(results: [place("使われない")])
        let outcome = await NLMemoComposer(parser: parser, searcher: searcher)
            .compose("牛乳を買う", favorites: [], near: nil, now: now(), calendar: calendar())
        guard case .draft(let d) = outcome else { Issue.record("draft ではない"); return }
        #expect(d.candidates.isEmpty)
        #expect(searcher.log.queries.isEmpty)
    }

    @Test("モデルが断った・失敗したときは、入力文を題にして戻す")
    func failure() async {
        let composer = NLMemoComposer(parser: FakeParser(result: .failure(SomeModelError())), searcher: FakeSearcher())
        let outcome = await composer.compose("  駅に着いたら\n牛乳  ", favorites: [], near: nil, now: now(), calendar: calendar())
        #expect(outcome == .fallback(title: "駅に着いたら 牛乳"))
    }

    @Test("空の入力は、題なしで戻す（モデルを呼ばない）")
    func emptyInput() async {
        let composer = NLMemoComposer(parser: FakeParser(result: .failure(SomeModelError())), searcher: FakeSearcher())
        #expect(await composer.compose("   ", favorites: [], near: nil) == .fallback(title: ""))
    }

    @Test("時間切れは、入力文を題にして戻す")
    func timeout() async {
        let slow = FakeParser(result: .success(NLParseResult(raw: NLMemoRaw(title: "遅い"))), delay: .seconds(30))
        var composer = NLMemoComposer(parser: slow, searcher: FakeSearcher())
        composer.timeout = .milliseconds(50)
        let outcome = await composer.compose("牛乳", favorites: [], near: nil, now: now(), calendar: calendar())
        #expect(outcome == .fallback(title: "牛乳"))
    }

    @Test("取り消されたら cancelled")
    func cancelled() async {
        let slow = FakeParser(result: .success(NLParseResult(raw: NLMemoRaw(title: "遅い"))), delay: .seconds(30))
        let composer = NLMemoComposer(parser: slow, searcher: FakeSearcher())
        let task = Task { await composer.compose("牛乳", favorites: [], near: nil, now: now(), calendar: calendar()) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == .cancelled)
    }
}

@Suite("評価用の例文")
struct NLEvalFixtureTests {
    @Test("日本語 20 件・英語 10 件、ID は重複しない")
    func counts() {
        let cases = NLEvalFixtures.cases
        #expect(cases.filter { $0.language == "ja" }.count == 20)
        #expect(cases.filter { $0.language == "en" }.count == 10)
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(cases.allSatisfy { NLInput.sanitize($0.text) != nil })
    }

    @Test("期待値が、検査のロジックを通る（モデルは呼ばない）")
    func expectationsAreValid() {
        for c in NLEvalFixtures.cases {
            let parts = c.window?.split(separator: "-").map(String.init)
            let raw = NLMemoRaw(
                title: c.titleKeyword, placeQuery: c.placeQuery, trigger: c.trigger,
                timeStart: parts?.first, timeEnd: parts?.last,
                days: c.days.split(separator: ",").map(String.init),
                deadline: c.deadlineRule == nil ? nil : "2026-11-27")
            let d = NLMemoNormalizer.draft(from: raw, originalText: c.text, now: now(), calendar: calendar())
            #expect(!d.title.isEmpty, "\(c.id)")
            if c.window != nil { #expect(d.timeWindow != nil, "\(c.id) の時間帯") }
            if !c.days.isEmpty { #expect(d.activeDays != nil, "\(c.id) の曜日") }
            if c.deadlineRule != nil { #expect(d.deadline != nil, "\(c.id) の期限") }
            if c.trigger != "unspecified" { #expect(NLMemoNormalizer.trigger(c.trigger) != nil, "\(c.id) の通知") }
            #expect(["fav", "search", "none"].contains(c.placeKind), "\(c.id)")
            #expect((c.placeKind == "none") == c.placeQuery.isEmpty, "\(c.id) の場所")
        }
    }
}

// MARK: - 追加（レビュー対応）

private func japaneseCalendar() -> Calendar {
    var c = Calendar(identifier: .japanese)
    c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return c
}

@Suite("グレゴリオ暦への固定")
struct NLGregorianTests {
    @Test("和暦の端末でも、期限 \"2026-11-27\" を 2026 年として読む")
    func deadlineJapaneseCalendar() throws {
        let d = try #require(NLMemoNormalizer.deadline("2026-11-27", now: now(), calendar: japaneseCalendar()))
        let c = calendar().dateComponents([.year, .month, .day, .hour, .minute], from: d)
        #expect(c.year == 2026 && c.month == 11 && c.day == 27 && c.hour == 23 && c.minute == 59)
    }

    @Test("指示文の今日の日付も、和暦の端末でグレゴリオ暦になる")
    func instructionsDate() {
        let text = SystemLanguageModelParser.instructions(today: now(), calendar: japaneseCalendar())
        #expect(text.contains("2026-11-21"))
        #expect(text.contains("Saturday"))
    }
}

@Suite("NLSearchRecords / 弱い一致 / 落とした項目")
struct NLSelectionTests {
    @Test("検索が複数回なら、場所の語に合う検索を使う。無ければ最後の検索。検索なしは nil")
    func pick() {
        let a = place("A店", lat: 35.1, lon: 139.1), b = place("B駅", lat: 35.2, lon: 139.2)
        let records = [NLSearchRecord(query: "ドラッグストア", places: [a]), NLSearchRecord(query: "駅", places: [b])]
        #expect(NLSearchRecords.pick(query: "ドラッグストア", from: records) == [a])
        #expect(NLSearchRecords.pick(query: "駅前のドラッグストア", from: records) == [a])   // 語が含み合う
        #expect(NLSearchRecords.pick(query: "郵便局", from: records) == [b])               // 合うものが無ければ最後
        #expect(NLSearchRecords.pick(query: nil, from: records) == [b])
        #expect(NLSearchRecords.pick(query: "x", from: []) == nil)
        #expect(NLSearchRecords.pick(query: "x", from: [NLSearchRecord(query: "x", places: [])]) == [])
    }

    @Test("ツールの検索は 2 回まで")
    func toolLimit() async {
        let recorder = NLPlaceRecorder()
        #expect(await recorder.reserve())
        #expect(await recorder.reserve())
        #expect(await recorder.reserve() == false)
    }

    @Test("弱い一致のお気に入りは、検索結果の後ろに出る。強い一致は前")
    func weakAfterSearch() {
        let weak = place("駅前ドラッグ", lat: 35.0, lon: 139.0)
        let strong = place("ドラッグ", lat: 35.5, lon: 139.5)
        let found = place("検索の店", lat: 35.2, lon: 139.2)
        #expect(PlaceResolver.strongMatches(for: "ドラッグ", in: [weak, strong]) == [strong])
        #expect(PlaceResolver.weakMatches(for: "ドラッグ", in: [weak, strong]) == [weak])
        let r = NLPlaceSelector.choose(query: "ドラッグ", favorites: [weak, strong], searched: [found], near: nil)
        #expect(r.map(\.place.name) == ["ドラッグ", "検索の店", "駅前ドラッグ"])
    }

    @Test("弱い一致だけでは補いの検索を省かない／強い一致なら省く")
    func weakDoesNotSkipSearch() async {
        let weak = place("駅前ドラッグ", lat: 35.0, lon: 139.0)
        let found = place("検索の店", lat: 35.2, lon: 139.2)
        let parser = FakeParser(result: .success(NLParseResult(raw: NLMemoRaw(title: "洗剤", placeQuery: "ドラッグ"))))
        let s1 = FakeSearcher(results: [found])
        let o1 = await NLMemoComposer(parser: parser, searcher: s1)
            .compose("ドラッグで洗剤", favorites: [weak], near: nil, now: now(), calendar: calendar())
        #expect(s1.log.queries == ["ドラッグ"])
        guard case .draft(let d1) = o1 else { Issue.record("draft ではない"); return }
        #expect(d1.candidates.map(\.place.name) == ["検索の店", "駅前ドラッグ"])

        let strong = place("ドラッグ", lat: 35.5, lon: 139.5)
        let s2 = FakeSearcher(results: [found])
        _ = await NLMemoComposer(parser: parser, searcher: s2)
            .compose("ドラッグで洗剤", favorites: [strong], near: nil, now: now(), calendar: calendar())
        #expect(s2.log.queries.isEmpty)
    }

    @Test("補いの検索に渡す語は 50 字に切る")
    func searchQueryTruncated() async {
        let long = String(repeating: "あ", count: 120)
        let parser = FakeParser(result: .success(NLParseResult(raw: NLMemoRaw(title: "t", placeQuery: long))))
        let searcher = FakeSearcher(results: [])
        _ = await NLMemoComposer(parser: parser, searcher: searcher)
            .compose("x", favorites: [], near: nil, now: now(), calendar: calendar())
        #expect(searcher.log.queries.first?.count == NLInput.maxSearchQueryLength)
    }

    @Test("捨てた項目: 片方だけの時刻・日をまたぐ時間帯・読めない曜日と期限")
    func dropped() {
        let raw = NLMemoRaw(title: "t", timeStart: "22:00", timeEnd: "06:00", days: ["blursday"], deadline: "soon")
        let d = NLMemoNormalizer.draft(from: raw, originalText: "x", now: now(), calendar: calendar())
        #expect(d.dropped == [.timeWindow, .days, .deadline])
        let half = NLMemoNormalizer.draft(from: NLMemoRaw(title: "t", timeStart: "16:00"), originalText: "x", now: now(), calendar: calendar())
        #expect(half.dropped == [.timeWindow])
        let ok = NLMemoNormalizer.draft(from: NLMemoRaw(title: "t", days: ["毎日"]), originalText: "x", now: now(), calendar: calendar())
        #expect(ok.dropped.isEmpty)   // 毎日は読めている
    }
}

// MARK: - 時間切れ・取り消し

/// テストが開けるまで待ち続ける門。取り消しには応じない（`withCheckedContinuation` は取り消しで抜けない）。
private nonisolated final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    /// 誰かが門の前に来たか（`wait()` を呼んだか）。
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    var isOpen: Bool { lock.withLock { opened } }
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            entered = true
            let waiters = enteredWaiters
            enteredWaiters = []
            if opened {
                lock.unlock()
                waiters.forEach { $0.resume() }
                c.resume()
                return
            }
            continuation = c
            lock.unlock()
            waiters.forEach { $0.resume() }
        }
    }
    /// 誰かが門の前に来るまで待つ（時間で待たず、取り消しを確実に「止まっている最中」に送るため）。
    func waitUntilEntered() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if entered { lock.unlock(); c.resume(); return }
            enteredWaiters.append(c)
            lock.unlock()
        }
    }
    func open() {
        lock.lock()
        opened = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

/// 取り消しに応じないモデル（門が開くまで返らない）。
private nonisolated struct StubbornParser: NLMemoParsing {
    let gate: Gate
    func parse(text: String, today: Date, calendar: Calendar, favorites: [PlaceCandidate], near: NLPoint?) async throws -> NLParseResult {
        await gate.wait()
        return NLParseResult(raw: NLMemoRaw(title: "遅れて届いた"))
    }
}
/// 取り消しに応じない地図の検索。
private nonisolated struct StubbornSearcher: NLPlaceSearching {
    let gate: Gate
    func search(query: String, near: NLPoint?) async -> [PlaceCandidate] {
        await gate.wait()
        return []
    }
}

/// 仕事が終わらないうちに返ったかを確かめる。時間ではなく「門が閉じたまま返ったか」で見る
/// （テストの実行環境が止まっても、結果が変わらないように）。
/// メインアクターの外で動かす（ほかのテストがメインアクターを長く使っていても、待たされないように）。
@concurrent
private nonisolated func composeWhileStuck(_ composer: NLMemoComposer, gate: Gate, cal: Calendar, date: Date,
                                           cancelWhenStuck: Bool = false) async -> (outcome: NLMemoOutcome, gateWasClosed: Bool) {
    let task = Task { await composer.compose("牛乳", favorites: [], near: nil, now: date, calendar: cal) }
    if cancelWhenStuck {
        // モデルが門の前で止まったのを確かめてから取り消す（決まった時間を待つと、重い環境では
        // 止まる前に取り消してしまい、時間切れまで待つことがあった）
        await gate.waitUntilEntered()
        task.cancel()
    }
    let outcome = await task.value
    let closed = !gate.isOpen
    gate.open()   // 後片付け
    return (outcome, closed)
}

// メインアクターで動かさない。ほかのスイート（SharedMemo の CRUD など）がメインアクターを長く使うと、
// 取り消し・時間切れの後の再開がそれを待ってしまい、何百秒もかかることがあった。
@Suite("時間切れと取り消し")
nonisolated struct NLTimeoutTests {
    @Test("取り消しに応じないモデルでも、時間切れで先に返る（遅れた結果は捨てる）")
    @concurrent func stubbornParserTimesOut() async {
        let gate = Gate()
        var composer = NLMemoComposer(parser: StubbornParser(gate: gate), searcher: FakeSearcher())
        composer.timeout = .milliseconds(100)
        let r = await composeWhileStuck(composer, gate: gate, cal: calendar(), date: now())
        #expect(r.outcome == .fallback(title: "牛乳"))
        #expect(r.gateWasClosed)
    }

    @Test("補いの検索が止まっていても、上限の内側で返る")
    @concurrent func stubbornSearchTimesOut() async {
        let gate = Gate()
        let parser = FakeParser(result: .success(NLParseResult(raw: NLMemoRaw(title: "洗剤", placeQuery: "ドラッグストア"))))
        var composer = NLMemoComposer(parser: parser, searcher: StubbornSearcher(gate: gate))
        composer.timeout = .milliseconds(100)
        let r = await composeWhileStuck(composer, gate: gate, cal: calendar(), date: now())
        #expect(r.outcome == .fallback(title: "牛乳"))
        #expect(r.gateWasClosed)
    }

    @Test("取り消しに応じないモデルでも、取り消しで先に返る", .timeLimit(.minutes(1)))
    @concurrent func stubbornParserCancelled() async {
        let gate = Gate()
        let composer = NLMemoComposer(parser: StubbornParser(gate: gate), searcher: FakeSearcher())
        let r = await composeWhileStuck(composer, gate: gate, cal: calendar(), date: now(), cancelWhenStuck: true)
        #expect(r.outcome == .cancelled)
        #expect(r.gateWasClosed)
    }
}

// MARK: - 画面の状態の遷移

@Suite("NLFlowReducer")
struct NLFlowReducerTests {
    private let home = NLPlace(latitude: 35.0, longitude: 139.0, name: "Loading...")
    private func fields(title: String = "", place: NLPlace? = nil) -> NLEditorFields {
        NLEditorFields(title: title, notifyOnEntry: true, notifyOnExit: true, timeWindow: nil, activeDays: nil,
                       deadline: nil, place: place ?? home)
    }
    private func draft(title: String = "牛乳", window: NLTimeWindow? = nil, days: [Int]? = nil, deadline: Date? = nil,
                       entry: Bool? = nil, exit: Bool? = nil, candidates: [PlaceCandidate] = []) -> NLMemoOutcome {
        .draft(NLMemoDraft(title: title, placeQuery: nil, notifyOnEntry: entry, notifyOnExit: exit, timeWindow: window,
                           activeDays: days, deadline: deadline,
                           candidates: candidates.map { NLPlaceChoice(place: $0, source: .search) }))
    }
    private let station = PlaceCandidate(id: UUID(), name: "駅", subtitle: "", latitude: 35.5, longitude: 139.5, iconName: "mappin.fill")
    private let window = NLTimeWindow(startMinutes: 960, endMinutes: 1140)

    @Test("読み取れたら、仮置きの場所に動き、確認が要る。文章に無い項目は触らない")
    func draftPlacesAndKeeps() {
        var current = fields(title: "")
        current.notifyOnExit = false        // 既存の設定
        let r = NLFlowReducer.reduce(flow: NLFlow(), current: current, titleAtStart: "",
                                     outcome: draft(entry: false, candidates: [station]))
        #expect(r.fields.title == "牛乳")
        #expect(r.fields.place.latitude == 35.5 && r.fields.place.name == "駅")
        #expect(r.flow.needsConfirmation)
        #expect(r.fields.notifyOnEntry == false)
        #expect(r.fields.notifyOnExit == false)   // nil なので既存のまま
        #expect(r.fields.timeWindow == nil)
    }

    @Test("2 回目が失敗したら、1 回目の場所・時間帯・曜日・期限を残さず、確認も要らない状態に戻る")
    func secondFailureReverts() {
        let first = NLFlowReducer.reduce(flow: NLFlow(), current: fields(), titleAtStart: "",
                                         outcome: draft(window: window, days: [1, 2], deadline: Date(timeIntervalSince1970: 2_000_000_000),
                                                        candidates: [station]))
        #expect(first.fields.timeWindow == window && first.flow.needsConfirmation)
        let second = NLFlowReducer.reduce(flow: first.flow, current: first.fields, titleAtStart: first.fields.title,
                                          outcome: .fallback(title: "別の文"))
        #expect(second.fields.place == home)                 // 仮置きの座標は残らない
        #expect(second.fields.timeWindow == nil && second.fields.activeDays == nil && second.fields.deadline == nil)
        #expect(second.fields.title == "別の文")
        #expect(second.flow.needsConfirmation == false && second.flow.choices.isEmpty)
        #expect(second.notice == .usedAsTitle)
    }

    @Test("2 回目が成功したら、1 回目だけが書いた項目は戻してから書く（nil の項目は 1 回目の値を残さない）")
    func secondSuccessReplaces() {
        let first = NLFlowReducer.reduce(flow: NLFlow(), current: fields(), titleAtStart: "",
                                         outcome: draft(window: window, candidates: [station]))
        let other = PlaceCandidate(id: UUID(), name: "郵便局", subtitle: "", latitude: 36, longitude: 140, iconName: "mappin.fill")
        let second = NLFlowReducer.reduce(flow: first.flow, current: first.fields, titleAtStart: first.fields.title,
                                          outcome: draft(title: "荷物", days: [5], candidates: [other]))
        #expect(second.fields.timeWindow == nil)
        #expect(second.fields.activeDays == [5])
        #expect(second.fields.place.name == "郵便局")
        #expect(second.flow.needsConfirmation)
    }

    @Test("2 回目が取り消されたら、何も変えない")
    func cancelledKeeps() {
        let first = NLFlowReducer.reduce(flow: NLFlow(), current: fields(), titleAtStart: "", outcome: draft(candidates: [station]))
        let second = NLFlowReducer.reduce(flow: first.flow, current: first.fields, titleAtStart: "", outcome: .cancelled)
        #expect(second.fields == first.fields && second.flow == first.flow)
    }

    @Test("手で直した項目は、次の読み取りで戻さない")
    func manualEditsKept() {
        let first = NLFlowReducer.reduce(flow: NLFlow(), current: fields(), titleAtStart: "",
                                         outcome: draft(days: [1], candidates: [station]))
        var edited = first.fields
        edited.activeDays = [2, 3]           // 手で直した
        let second = NLFlowReducer.reduce(flow: first.flow, current: edited, titleAtStart: edited.title,
                                          outcome: .fallback(title: "x"))
        #expect(second.fields.activeDays == [2, 3])
    }

    @Test("読み取り中に手で打った題は上書きしない")
    func typedTitleKept() {
        var current = fields(title: "")
        current.title = "手で打った"          // 読み取りの開始時 (titleAtStart) は空
        let r = NLFlowReducer.reduce(flow: NLFlow(), current: current, titleAtStart: "", outcome: draft(candidates: [station]))
        #expect(r.fields.title == "手で打った")
        let f = NLFlowReducer.reduce(flow: NLFlow(), current: current, titleAtStart: "", outcome: .fallback(title: "文"))
        #expect(f.fields.title == "手で打った")
    }

    @Test("候補なしの読み取りは、場所を動かさず、確認は要る")
    func noCandidates() {
        let r = NLFlowReducer.reduce(flow: NLFlow(), current: fields(), titleAtStart: "", outcome: draft())
        #expect(r.fields.place == home)
        #expect(r.flow.needsConfirmation)
    }

    @Test("確認・候補の選択・地図での選び直しで、確認済みになる")
    func confirmations() {
        let r = NLFlowReducer.reduce(flow: NLFlow(), current: fields(), titleAtStart: "", outcome: draft(candidates: [station]))
        #expect(NLFlowReducer.confirm(r.flow).needsConfirmation == false)
        #expect(NLFlowReducer.pickedOnMap(r.flow).needsConfirmation == false)
        let choice = NLPlaceChoice(place: station, source: .search)
        let s = NLFlowReducer.select(choice, flow: r.flow, current: r.fields)
        #expect(s.flow.needsConfirmation == false && s.flow.selectedID == choice.id)
    }

    @Test("逆ジオコーディングの結果: 仮置き中でも、元の場所の名前を控えて、戻したときに使う")
    func geocodedDuringProvisional() {
        let r = NLFlowReducer.reduce(flow: NLFlow(), current: fields(), titleAtStart: "", outcome: draft(candidates: [station]))
        // 仮置き中に、元の座標 (35.0, 139.0) の名前が返ってくる
        let g = NLFlowReducer.geocoded(name: "渋谷区", latitude: 35.0, longitude: 139.0, flow: r.flow, current: r.fields)
        #expect(g.fields.place.name == "駅")                       // 画面は仮置きの名前のまま
        #expect(g.flow.applied?.before.place.name == "渋谷区")
        let back = NLFlowReducer.reduce(flow: g.flow, current: g.fields, titleAtStart: "", outcome: .fallback(title: "x"))
        #expect(back.fields.place.name == "渋谷区")                // "Loading..." のままにならない
    }

    @Test("逆ジオコーディングの結果: 画面がその座標のままなら名前を入れる")
    func geocodedPlain() {
        let g = NLFlowReducer.geocoded(name: "渋谷区", latitude: 35.0, longitude: 139.0, flow: NLFlow(), current: fields())
        #expect(g.fields.place.name == "渋谷区")
        let other = NLFlowReducer.geocoded(name: "渋谷区", latitude: 36.0, longitude: 139.0, flow: NLFlow(), current: fields())
        #expect(other.fields.place.name == "Loading...")           // 別の座標の結果は入れない
    }
}

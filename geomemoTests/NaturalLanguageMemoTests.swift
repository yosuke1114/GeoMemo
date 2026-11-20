import Testing
import Foundation
@testable import geomemo

// 文章でメモを作る (L-4) の純粋なロジックのテスト。端末内モデルは呼ばない（偽の parser / searcher を使う）。

private func calendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}
/// 2026-11-21 (土) 12:00 JST
private func now() -> Date {
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
                                                              searchedPlaces: [fromTool])))
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
                days: c.days.split(separator: ",").map(String.init), deadline: nil)
            let d = NLMemoNormalizer.draft(from: raw, originalText: c.text, now: now(), calendar: calendar())
            #expect(!d.title.isEmpty, "\(c.id)")
            if c.window != nil { #expect(d.timeWindow != nil, "\(c.id) の時間帯") }
            if !c.days.isEmpty { #expect(d.activeDays != nil, "\(c.id) の曜日") }
            if c.trigger != "unspecified" { #expect(NLMemoNormalizer.trigger(c.trigger) != nil, "\(c.id) の通知") }
            #expect(["fav", "search", "none"].contains(c.placeKind), "\(c.id)")
            #expect((c.placeKind == "none") == c.placeQuery.isEmpty, "\(c.id) の場所")
        }
    }
}

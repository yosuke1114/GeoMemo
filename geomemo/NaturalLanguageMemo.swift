import Foundation

// 「文章でメモを作る」(L-4) の純粋なロジック。
// モデルの出力 (NLMemoRaw) を、画面に載せられる下書き (NLMemoDraft) に変換する。
// FoundationModels・SwiftData・MapKit・UI には依存しない（値型だけ）。どのスレッドからでも呼べて、単体テストでモデルを呼ばない。
// 文章はモデルが端末内で処理する。場所の検索だけは、検索語とおおよその範囲が Apple のマップに送られる（検索語は短く切る）。
// プロジェクトの既定は MainActor なので、ここは明示的に nonisolated にする。

// MARK: - 値型

/// 緯度・経度の組。モデルのツールやバックグラウンドへ渡せるよう Sendable にしてある。
nonisolated struct NLPoint: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

/// モデルが返した値をそのまま写したもの。まだ何も検査していない。
nonisolated struct NLMemoRaw: Equatable, Sendable {
    /// 用事（場所や時間を除いた短い題）。
    var title: String = ""
    /// 場所の名前や検索語。文に場所が無ければ空。座標ではない。
    var placeQuery: String = ""
    /// "arrive" / "leave" / "both" / "unspecified"
    var trigger: String = "unspecified"
    /// "HH:mm"（時間帯の始まり）。無ければ nil。
    var timeStart: String?
    /// "HH:mm"（時間帯の終わり）。無ければ nil。
    var timeEnd: String?
    /// 曜日。"mon"〜"sun"、"weekdays"、"weekends" など。
    var days: [String] = []
    /// "yyyy-MM-dd"（この日まで有効）。無ければ nil。
    var deadline: String?
}

/// 時間帯 (分、0...1439)。始まり < 終わり であることを保証する。
nonisolated struct NLTimeWindow: Equatable, Sendable {
    let startMinutes: Int
    let endMinutes: Int
}

/// 画面に載せる下書き。値は全部検査済み。nil は「文章に無かった（既定のまま）」。
nonisolated struct NLMemoDraft: Equatable, Sendable {
    var title: String
    /// 文章から読み取った場所の語（候補の検索に使った語）。
    var placeQuery: String?
    /// nil なら通知の設定は既定のまま。
    var notifyOnEntry: Bool?
    var notifyOnExit: Bool?
    var timeWindow: NLTimeWindow?
    /// 0=日〜6=土（`GeoMemo.activeDays` と同じ）。昇順・重複なし。nil なら毎日。
    var activeDays: [Int]?
    var deadline: Date?
    /// 場所の候補。先頭がいちばん有力。空なら地図で選んでもらう。
    var candidates: [NLPlaceChoice]
    /// モデルは値を返したが、読めない・使えないので捨てた項目。画面で一言出す。
    var dropped: [NLDroppedItem] = []
}

nonisolated enum NLDroppedItem: Equatable, Sendable {
    case timeWindow, days, deadline
}

/// 場所の候補 1 件と、その出どころ（お気に入りの場所か、地図の検索か）。
nonisolated struct NLPlaceChoice: Equatable, Sendable, Identifiable {
    enum Source: Equatable, Sendable { case favorite, search }
    let place: PlaceCandidate
    let source: Source
    var id: UUID { place.id }
}

// MARK: - 入力文のサニタイズ

nonisolated enum NLInput {
    /// 入力文の最大の長さ。1〜2 文の想定なので、長い貼り付けはここで切る。
    nonisolated static let maxLength = 200

    /// 制御文字・改行を空白にし、連続する空白を 1 つにして、前後を落とし、長すぎれば切る。空なら nil。
    nonisolated static func sanitize(_ text: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0x0A || v == 0x0D || v == 0x09 || v == 0x2028 || v == 0x2029 {
                scalars.append(" ")   // 改行・タブは単語の区切りとして空白に
            } else if scalar.properties.generalCategory == .control || isInvisibleControl(v) {
                continue
            } else {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0 == " " || $0 == "\u{3000}" })
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 表示を偽装できる・見えない制御だけを落とす。
    /// 方向制御 (U+202A–202E, U+2066–2069, U+200E/200F, U+061C)、ゼロ幅スペース (U+200B)、BOM (U+FEFF)、語結合子 (U+2060)。
    /// 絵文字の結合 (U+200D)、U+200C、タグ文字 (U+E0020–E007F、旗の絵文字)、異体字選択子は残す。
    nonisolated static func isInvisibleControl(_ v: UInt32) -> Bool {
        (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
            || v == 0x200E || v == 0x200F || v == 0x061C || v == 0x200B || v == 0xFEFF || v == 0x2060
    }

    /// 地図の検索に送る語の最大の長さ。
    nonisolated static let maxSearchQueryLength = 50

    /// 地図の検索（Apple のマップ）に送る語。サニタイズして短く切る。
    nonisolated static func searchQuery(_ text: String) -> String? {
        guard let s = sanitize(text) else { return nil }
        return String(s.prefix(maxSearchQueryLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 出力の検証と丸め

nonisolated enum NLMemoNormalizer {
    /// 題の最大の長さ。
    nonisolated static let maxTitleLength = 80
    /// 期限として受け入れる最大の先 (日)。それより先は読み違いとみなす。
    nonisolated static let maxDeadlineDays = 366 * 2

    /// 通知の種別。unspecified は設定を触らない。
    nonisolated static func trigger(_ text: String) -> (entry: Bool, exit: Bool)? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "arrive", "arrival", "entry", "enter", "着いたら", "到着": return (true, false)
        case "leave", "exit", "depart", "departure", "出たら", "出発", "退出": return (false, true)
        case "both": return (true, true)
        default: return nil
        }
    }

    /// "17:00" "9:5" "17" "17時" "5:30pm" を分 (0...1439) にする。読めなければ nil。24:00 は 1439。
    nonisolated static func minutes(from text: String) -> Int? {
        var s = text.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        var isPM: Bool?
        if s.hasSuffix("pm") { isPM = true; s.removeLast(2) } else if s.hasSuffix("am") { isPM = false; s.removeLast(2) }
        s = s.replacingOccurrences(of: "時", with: ":").replacingOccurrences(of: "分", with: "")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ": ")).trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), let hour = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        var minute = 0
        if parts.count == 2 {
            // 分が読めない（"17:xx"）ときは時刻ごと読めないものとする。
            guard let m = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            minute = m
        }
        var h = hour
        if let isPM {
            guard (1...12).contains(h) else { return nil }
            h = (h % 12) + (isPM ? 12 : 0)
        }
        guard (0...24).contains(h), (0...59).contains(minute) else { return nil }
        let total = h * 60 + minute
        guard total <= 24 * 60 else { return nil }
        return min(total, 1439)
    }

    /// 時間帯。片方だけ・読めない・終わりが始まり以前（日をまたぐ指定）・長さ 0 のものは nil。
    /// 通知の判定 (`TriggerConditions`) が日をまたぐ時間帯を扱えないので、またぐ指定は付けずに作成画面で選んでもらう。
    nonisolated static func timeWindow(start: String?, end: String?) -> NLTimeWindow? {
        guard let start, let end, let s = minutes(from: start), let e = minutes(from: end), s < e else { return nil }
        return NLTimeWindow(startMinutes: s, endMinutes: e)
    }

    /// 曜日の語を読む。読めた曜日と、読めなかった語の数を返す。
    nonisolated static func parseDays(_ tokens: [String]) -> (days: Set<Int>, unreadable: Int, everyDay: Bool) {
        var days = Set<Int>()
        var unreadable = 0
        var everyDay = false
        for raw in tokens {
            let t = raw.precomposedStringWithCompatibilityMapping
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !t.isEmpty else { continue }
            if ["everyday", "every day", "daily", "all", "毎日"].contains(t) { everyDay = true; days.formUnion(0...6); continue }
            if t.contains("平日") || t.hasPrefix("weekday") { days.formUnion(1...5); continue }
            if t.contains("週末") || t.contains("土日") || t.hasPrefix("weekend") { days.formUnion([0, 6]); continue }
            let english = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            if let i = english.firstIndex(where: { t.hasPrefix($0) }) { days.insert(i); continue }
            // 日本語: 「月」「月曜」「月曜日」。複数並んでいる場合 (「月水金」) も拾う。
            let jp = Array("日月火水木金土")
            let body = t.replacingOccurrences(of: "曜日", with: "").replacingOccurrences(of: "曜", with: "")
            let hits = body.compactMap { jp.firstIndex(of: $0) }
            if !hits.isEmpty, hits.count == body.count { days.formUnion(hits) } else { unreadable += 1 }
        }
        return (days, unreadable, everyDay)
    }

    /// 曜日を 0=日〜6=土 の昇順・重複なしにする。読めない語は無視。毎日（7 日すべて）・空は nil。
    nonisolated static func activeDays(_ tokens: [String]) -> [Int]? {
        let parsed = parseDays(tokens)
        guard !parsed.days.isEmpty, parsed.days.count < 7 else { return nil }
        return parsed.days.sorted()
    }

    /// 暦の種類にかかわらず、グレゴリオ暦で読む（タイムゾーンだけ引き継ぐ）。和暦などの端末でも "2026-11-27" を 2026 年として読むため。
    nonisolated static func gregorian(like calendar: Calendar) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = calendar.timeZone
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    /// "yyyy-MM-dd" をその日の 23:59 にする。読めない・今日より前・遠すぎる (約 2 年超) ものは nil。
    nonisolated static func deadline(_ text: String?, now: Date, calendar inputCalendar: Calendar) -> Date? {
        guard let text else { return nil }
        let calendar = gregorian(like: inputCalendar)
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.prefix(10).split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard s.count >= 10, parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        comps.hour = 23; comps.minute = 59; comps.second = 0
        guard let date = calendar.date(from: comps),
              // 2 月 30 日のような存在しない日付は、Calendar が繰り上げるので成分を見て弾く。
              calendar.component(.day, from: date) == parts[2], calendar.component(.month, from: date) == parts[1]
        else { return nil }
        let startOfToday = calendar.startOfDay(for: now)
        guard date >= startOfToday else { return nil }
        guard let limit = calendar.date(byAdding: .day, value: maxDeadlineDays, to: startOfToday), date <= limit else { return nil }
        return date
    }

    /// 題。前後の空白と改行を落とし、長ければ切る。
    nonisolated static func cleanTitle(_ text: String) -> String {
        let one = NLInput.sanitize(text) ?? ""
        guard one.count > maxTitleLength else { return one }
        return String(one.prefix(maxTitleLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// モデルの出力を下書きにする。題が空なら入力文をそのまま題にする。候補は別に付ける。
    nonisolated static func draft(from raw: NLMemoRaw, originalText: String, now: Date, calendar: Calendar,
                                  candidates: [NLPlaceChoice] = []) -> NLMemoDraft {
        var title = cleanTitle(raw.title)
        if title.isEmpty { title = cleanTitle(originalText) }
        let query = NLInput.sanitize(raw.placeQuery)
        let trig = trigger(raw.trigger)
        let window = timeWindow(start: raw.timeStart, end: raw.timeEnd)
        let days = activeDays(raw.days)
        let dl = deadline(raw.deadline, now: now, calendar: calendar)
        var dropped: [NLDroppedItem] = []
        func filled(_ s: String?) -> Bool { !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if window == nil, filled(raw.timeStart) || filled(raw.timeEnd) { dropped.append(.timeWindow) }
        let parsedDays = parseDays(raw.days)
        if days == nil, parsedDays.days.isEmpty, parsedDays.unreadable > 0 { dropped.append(.days) }
        if dl == nil, filled(raw.deadline) { dropped.append(.deadline) }
        return NLMemoDraft(
            title: title,
            placeQuery: query,
            notifyOnEntry: trig?.entry,
            notifyOnExit: trig?.exit,
            timeWindow: window,
            activeDays: days,
            deadline: dl,
            candidates: candidates,
            dropped: dropped)
    }
}

// MARK: - 場所の候補の選び方

nonisolated enum NLPlaceSelector {
    /// 候補の最大数。
    nonisolated static let maxCandidates = 5
    /// 同じ場所とみなす距離 (m)。
    nonisolated static let duplicateDistance: Double = 40

    nonisolated static func isValid(_ place: PlaceCandidate) -> Bool {
        place.latitude.isFinite && place.longitude.isFinite
            && (-90...90).contains(place.latitude) && (-180...180).contains(place.longitude)
            && !(place.latitude == 0 && place.longitude == 0)
            && !place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 2 点の距離 (m、大円距離)。
    nonisolated static func distance(_ a: NLPoint, _ b: NLPoint) -> Double {
        let r = 6_371_000.0
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// 候補を決める。
    /// 1. お気に入りの場所のうち、強い一致（完全一致・別名・前方一致。`PlaceResolver` と同じ規則）。
    /// 2. 地図の検索結果（現在地があれば近い順）。お気に入りと同じ場所・同じ名前のものは省く。
    /// 3. お気に入りの弱い一致（名前に含む・住所に含む）。検索結果の後ろに添える。
    /// 座標が壊れている候補は除く。最大 `maxCandidates` 件。
    nonisolated static func choose(query: String?, favorites: [PlaceCandidate], searched: [PlaceCandidate],
                                   near: NLPoint?) -> [NLPlaceChoice] {
        var result: [NLPlaceChoice] = []
        func point(_ p: PlaceCandidate) -> NLPoint { NLPoint(latitude: p.latitude, longitude: p.longitude) }
        func isDuplicate(_ p: PlaceCandidate) -> Bool {
            result.contains { existing in
                let d = distance(point(existing.place), point(p))
                return existing.place.id == p.id
                    || (PlaceResolver.normalize(existing.place.name) == PlaceResolver.normalize(p.name) && d < 500)
                    || d < duplicateDistance
            }
        }
        var strong: [PlaceCandidate] = [], weak: [PlaceCandidate] = []
        if let query, !query.isEmpty {
            strong = PlaceResolver.strongMatches(for: query, in: favorites)
            weak = PlaceResolver.weakMatches(for: query, in: favorites)
        }
        for p in strong where isValid(p) && !isDuplicate(p) { result.append(NLPlaceChoice(place: p, source: .favorite)) }
        var rest = searched.filter(isValid)
        if let near {
            // 並べ替えは安定させる（同じ距離なら元の順）。
            rest = rest.enumerated().sorted { l, r in
                let dl = distance(near, point(l.element)), dr = distance(near, point(r.element))
                return dl == dr ? l.offset < r.offset : dl < dr
            }.map(\.element)
        }
        for p in rest where !isDuplicate(p) { result.append(NLPlaceChoice(place: p, source: .search)) }
        for p in weak where isValid(p) && !isDuplicate(p) { result.append(NLPlaceChoice(place: p, source: .favorite)) }
        return Array(result.prefix(maxCandidates))
    }
}

// MARK: - 差し替えできる境目

/// ツールの検索 1 回分。検索語と、その結果。
nonisolated struct NLSearchRecord: Equatable, Sendable {
    let query: String
    let places: [PlaceCandidate]
}

nonisolated enum NLSearchRecords {
    /// モデルが何回か検索したときに、どれを使うか。場所の語に合う検索（語が互いに含み合う）のうち最後のもの、
    /// 無ければ最後の検索。検索が 1 回もなければ nil（nil と「検索したが 0 件」を区別する）。
    nonisolated static func pick(query: String?, from records: [NLSearchRecord]) -> [PlaceCandidate]? {
        guard let last = records.last else { return nil }
        if let query {
            let q = PlaceResolver.normalize(query)
            // 語が互いに含み合う検索のうち、検索語がいちばん長い（具体的な）もの。同じ長さなら後の検索。
            var best: (length: Int, places: [PlaceCandidate])?
            for record in records {
                let r = PlaceResolver.normalize(record.query)
                guard !q.isEmpty, !r.isEmpty, r == q || r.contains(q) || q.contains(r) else { continue }
                if best == nil || r.count >= best!.length { best = (r.count, record.places) }
            }
            if let best { return best.places }
        }
        return last.places
    }
}

/// モデルの 1 回の呼び出しの結果。
nonisolated struct NLParseResult: Sendable {
    var raw: NLMemoRaw
    /// モデルがツールで引いた、地図の検索（呼び出し順）。座標はツールが作った値で、モデルが作った値ではない。
    var searches: [NLSearchRecord] = []
}

/// 文章を読み取るもの。実機では `SystemLanguageModel`、テストでは偽物。
nonisolated protocol NLMemoParsing: Sendable {
    func parse(text: String, today: Date, calendar: Calendar,
               favorites: [PlaceCandidate], near: NLPoint?) async throws -> NLParseResult
}

/// 場所の名前から地図で探すもの。実機では `MKLocalSearch`、テストでは偽物。
nonisolated protocol NLPlaceSearching: Sendable {
    func search(query: String, near: NLPoint?) async -> [PlaceCandidate]
}

nonisolated enum NLMemoOutcome: Equatable, Sendable {
    /// 読み取れた。場所の確認は呼び出し側が必ず挟む。
    case draft(NLMemoDraft)
    /// 断られた・失敗した・時間切れ。入力文を題として通常の作成画面に渡す。
    case fallback(title: String)
    /// 呼び出しが取り消された。何もしない。
    case cancelled
}

/// 入力文 → 下書き の流れ。サニタイズ、モデル、候補の選び方、失敗時の戻し方をまとめる。
nonisolated struct NLMemoComposer: Sendable {
    let parser: any NLMemoParsing
    let searcher: any NLPlaceSearching
    /// モデルの呼び出しと補いの検索を合わせた待ち時間の上限。
    var timeout: Duration = .seconds(45)

    nonisolated func compose(_ input: String, favorites: [PlaceCandidate], near: NLPoint?,
                             now: Date = Date(), calendar: Calendar = .current) async -> NLMemoOutcome {
        guard let text = NLInput.sanitize(input) else { return .fallback(title: "") }
        let fallbackTitle = NLMemoNormalizer.cleanTitle(text)
        let parser = parser, searcher = searcher

        do {
            // 読み取りも補いの検索も、上限の内側。先に終わった方を返し、遅れた結果は捨てる。
            return try await Self.withTimeout(timeout) {
                let parsed = try await parser.parse(text: text, today: now, calendar: calendar, favorites: favorites, near: near)
                let query = NLInput.sanitize(parsed.raw.placeQuery)
                var searched = NLSearchRecords.pick(query: query, from: parsed.searches)
                // ツールで検索されていなければ（モデルが呼ばなかった）、強い一致のお気に入りが無いときだけ自分で探す。
                if searched == nil, let q = NLInput.searchQuery(parsed.raw.placeQuery),
                   PlaceResolver.strongMatches(for: q, in: favorites).isEmpty {
                    searched = await searcher.search(query: q, near: near)
                }
                let candidates = NLPlaceSelector.choose(query: query, favorites: favorites,
                                                        searched: searched ?? [], near: near)
                return .draft(NLMemoNormalizer.draft(from: parsed.raw, originalText: text, now: now,
                                                     calendar: calendar, candidates: candidates))
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            // 安全フィルタで断られた・言語が非対応・文脈が足りない・時間切れなど。理由は問わず、入力文を題にして戻す。
            return Task.isCancelled ? .cancelled : .fallback(title: fallbackTitle)
        }
    }

    /// 一定時間で打ち切る。時間切れは `NLTimeoutError`。取り消しは `CancellationError`。
    /// 仕事（work）が取り消しに応じなくても、時間切れ・取り消しの時点で返る（構造化された TaskGroup だと、子の終了を待ってしまう）。
    nonisolated static func withTimeout<T: Sendable>(_ limit: Duration,
                                                     _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = NLFirstResult<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                race.start(continuation, limit: limit, work: work)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}

nonisolated struct NLTimeoutError: Error, Equatable {}

/// 仕事と時計の競争。先に着いた結果だけを 1 回返し、残りは取り消して捨てる。
nonisolated final class NLFirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    nonisolated func start(_ continuation: CheckedContinuation<T, Error>, limit: Duration,
                           work: @escaping @Sendable () async throws -> T) {
        lock.lock()
        if let result {   // 開始前に取り消されていた
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let worker = Task { [self] in
            do { finish(.success(try await work())) } catch { finish(.failure(error)) }
        }
        let timer = Task { [self] in
            do { try await Task.sleep(for: limit) } catch { return }
            finish(.failure(NLTimeoutError()))
        }
        lock.lock()
        let alreadyDone = result != nil
        if !alreadyDone { tasks = [worker, timer] }
        lock.unlock()
        if alreadyDone { worker.cancel(); timer.cancel() }
    }

    nonisolated func finish(_ new: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = new
        let continuation = continuation
        self.continuation = nil
        let toCancel = tasks
        tasks = []
        lock.unlock()
        toCancel.forEach { $0.cancel() }
        continuation?.resume(with: new)
    }
}

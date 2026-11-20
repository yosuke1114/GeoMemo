import Foundation

// 「文章でメモを作る」(L-4) の純粋なロジック。
// モデルの出力 (NLMemoRaw) を、画面に載せられる下書き (NLMemoDraft) に変換する。
// FoundationModels・SwiftData・MapKit・UI には依存しない（値型だけ）。どのスレッドからでも呼べて、単体テストでモデルを呼ばない。
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
            let isControl = scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format   // 書式制御・方向制御 (U+202E など)
                || v == 0x2028 || v == 0x2029
            if isControl {
                // 改行・タブは単語の区切りとして空白に。それ以外の制御文字は捨てる。
                if v == 0x0A || v == 0x0D || v == 0x09 || v == 0x2028 || v == 0x2029 { scalars.append(" ") }
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
        let minute = parts.count == 2 ? (Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0) : 0
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

    /// 曜日を 0=日〜6=土 の昇順・重複なしにする。読めない語は無視。毎日（7 日すべて）・空は nil。
    nonisolated static func activeDays(_ tokens: [String]) -> [Int]? {
        var days = Set<Int>()
        for raw in tokens {
            let t = raw.precomposedStringWithCompatibilityMapping
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !t.isEmpty else { continue }
            if t.contains("平日") || t.hasPrefix("weekday") { days.formUnion(1...5); continue }
            if t.contains("週末") || t.contains("土日") || t.hasPrefix("weekend") { days.formUnion([0, 6]); continue }
            if t.contains("毎日") || t.hasPrefix("every") || t == "daily" || t == "all" { days.formUnion(0...6); continue }
            let english = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            if let i = english.firstIndex(where: { t.hasPrefix($0) }) { days.insert(i); continue }
            // 日本語: 「月」「月曜」「月曜日」。複数並んでいる場合 (「月水金」) も拾う。
            let jp = Array("日月火水木金土")
            let body = t.replacingOccurrences(of: "曜日", with: "").replacingOccurrences(of: "曜", with: "")
            let hits = body.compactMap { jp.firstIndex(of: $0) }
            if !hits.isEmpty, hits.count == body.count { days.formUnion(hits) }
        }
        guard !days.isEmpty, days.count < 7 else { return nil }
        return days.sorted()
    }

    /// "yyyy-MM-dd" をその日の 23:59 にする。読めない・今日より前・遠すぎる (約 2 年超) ものは nil。
    nonisolated static func deadline(_ text: String?, now: Date, calendar: Calendar) -> Date? {
        guard let text else { return nil }
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
        return NLMemoDraft(
            title: title,
            placeQuery: query,
            notifyOnEntry: trig?.entry,
            notifyOnExit: trig?.exit,
            timeWindow: timeWindow(start: raw.timeStart, end: raw.timeEnd),
            activeDays: activeDays(raw.days),
            deadline: deadline(raw.deadline, now: now, calendar: calendar),
            candidates: candidates)
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
    /// 1. お気に入りの場所で、検索語に当てはまるもの（強い順。`PlaceResolver` と同じ規則）。
    /// 2. 地図の検索結果（現在地があれば近い順）。お気に入りと同じ場所・同じ名前のものは省く。
    /// 座標が壊れている候補は除く。最大 `maxCandidates` 件。
    nonisolated static func choose(query: String?, favorites: [PlaceCandidate], searched: [PlaceCandidate],
                                   near: NLPoint?) -> [NLPlaceChoice] {
        var result: [NLPlaceChoice] = []
        func isDuplicate(_ p: PlaceCandidate) -> Bool {
            result.contains { existing in
                existing.place.id == p.id
                    || (PlaceResolver.normalize(existing.place.name) == PlaceResolver.normalize(p.name)
                        && distance(NLPoint(latitude: existing.place.latitude, longitude: existing.place.longitude),
                                    NLPoint(latitude: p.latitude, longitude: p.longitude)) < 500)
                    || distance(NLPoint(latitude: existing.place.latitude, longitude: existing.place.longitude),
                                NLPoint(latitude: p.latitude, longitude: p.longitude)) < duplicateDistance
            }
        }
        if let query, !query.isEmpty {
            for p in PlaceResolver.matching(query, in: favorites) where isValid(p) && !isDuplicate(p) {
                result.append(NLPlaceChoice(place: p, source: .favorite))
            }
        }
        var rest = searched.filter(isValid)
        if let near {
            // 並べ替えは安定させる（同じ距離なら元の順）。
            rest = rest.enumerated().sorted { l, r in
                let dl = distance(near, NLPoint(latitude: l.element.latitude, longitude: l.element.longitude))
                let dr = distance(near, NLPoint(latitude: r.element.latitude, longitude: r.element.longitude))
                return dl == dr ? l.offset < r.offset : dl < dr
            }.map(\.element)
        }
        for p in rest where !isDuplicate(p) {
            result.append(NLPlaceChoice(place: p, source: .search))
        }
        return Array(result.prefix(maxCandidates))
    }
}

// MARK: - 差し替えできる境目

/// モデルの 1 回の呼び出しの結果。
nonisolated struct NLParseResult: Sendable {
    var raw: NLMemoRaw
    /// モデルがツールで引いた、地図の検索結果。座標はツールが作った値で、モデルが作った値ではない。
    var searchedPlaces: [PlaceCandidate] = []
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
    /// モデルの呼び出しの待ち時間の上限。
    var timeout: Duration = .seconds(45)

    nonisolated func compose(_ input: String, favorites: [PlaceCandidate], near: NLPoint?,
                             now: Date = Date(), calendar: Calendar = .current) async -> NLMemoOutcome {
        guard let text = NLInput.sanitize(input) else { return .fallback(title: "") }
        let fallbackTitle = NLMemoNormalizer.cleanTitle(text)

        let parsed: NLParseResult
        do {
            parsed = try await Self.withTimeout(timeout) {
                try await parser.parse(text: text, today: now, calendar: calendar, favorites: favorites, near: near)
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            // 安全フィルタで断られた・言語が非対応・文脈が足りない・時間切れなど。理由は問わず、入力文を題にして戻す。
            return Task.isCancelled ? .cancelled : .fallback(title: fallbackTitle)
        }
        if Task.isCancelled { return .cancelled }

        let query = NLInput.sanitize(parsed.raw.placeQuery)
        var searched = parsed.searchedPlaces
        // ツールで検索されていなければ（モデルが呼ばなかった）、お気に入りで足りないときだけ自分で探す。
        if let query, searched.isEmpty, PlaceResolver.matching(query, in: favorites).isEmpty {
            searched = await searcher.search(query: query, near: near)
            if Task.isCancelled { return .cancelled }
        }
        let candidates = NLPlaceSelector.choose(query: query, favorites: favorites, searched: searched, near: near)
        return .draft(NLMemoNormalizer.draft(from: parsed.raw, originalText: text, now: now,
                                             calendar: calendar, candidates: candidates))
    }

    /// 一定時間で打ち切る。時間切れは `TimeoutError`。
    nonisolated static func withTimeout<T: Sendable>(_ limit: Duration,
                                                     _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw NLTimeoutError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw NLTimeoutError() }
            return first
        }
    }
}

nonisolated struct NLTimeoutError: Error, Equatable {}

import Foundation

// メモの作成・編集画面の表示判断に使う純粋なロジック (テスト対象)。
// プロジェクトは既定が MainActor なので、ここは明示的に nonisolated にする。

/// 範囲 (半径, m) の既定値・下限・上限・丸め。値は設定画面の候補 (50M〜1KM) とそろえてある。
nonisolated enum RadiusPolicy {
    nonisolated static let minimum: Double = 50
    nonisolated static let maximum: Double = 1000
    nonisolated static let defaultValue: Double = 100
    nonisolated static let step: Double = 10
    /// これより小さいと建物の中では反応しにくい。
    nonisolated static let indoorThreshold: Double = 100
    /// 素早く選ぶための候補 (従来の 4 択)。
    nonisolated static let presets: [Double] = [50, 100, 500, 1000]

    /// 下限〜上限に収める。数値でない値は既定値にする。
    nonisolated static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, minimum), maximum)
    }

    /// 刻み (10m) に丸めてから、下限〜上限に収める。
    nonisolated static func snapped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return clamp((value / step).rounded() * step)
    }

    /// スライダーの範囲。すでに上限を超えて保存されているメモも、値を変えずに開けるよう上限を広げる。
    nonisolated static func sliderRange(including current: Double) -> ClosedRange<Double> {
        let upper = current.isFinite ? max(maximum, current) : maximum
        return minimum...upper
    }

    nonisolated static func isTooSmallForIndoors(_ radius: Double) -> Bool {
        radius.isFinite && radius < indoorThreshold
    }

    /// 地図に表示する縦の幅 (m)。円が画面の 8 割以内に収まる最小の段。
    /// 段を粗くして、スライダーを動かしている間は拡大率が変わらず、円の大きさの変化が見えるようにする。
    nonisolated static let mapSpanSteps: [Double] = [250, 500, 1000, 2000, 4000]

    nonisolated static func mapSpanMeters(for radius: Double) -> Double {
        let diameter = (radius.isFinite ? max(radius, 0) : defaultValue) * 2
        let needed = diameter / 0.8
        return mapSpanSteps.first(where: { $0 >= needed }) ?? (mapSpanSteps.last ?? 4000)
    }

    /// 「150M」「1.2KM」(従来の詳細画面と同じ表記)。
    nonisolated static func label(_ radius: Double) -> String {
        if radius >= 1000 { return String(format: "%.1fKM", radius / 1000) }
        return "\(Int(radius))M"
    }

    /// VoiceOver 用の読み上げ。
    nonisolated static func spokenValue(_ radius: Double) -> String {
        String(format: String(localized: "%d meters"), Int(radius.rounded()))
    }
}

/// 「詳細」にある項目のうち、いま設定済みのもの。
nonisolated enum MemoAdvancedItem: Equatable, Sendable {
    case note
    case checklist(count: Int)
    case photo
    case color
    case tags(count: Int)
    case expiry
    case timeWindow(startMinutes: Int, endMinutes: Int)
    case days(count: Int)
    case route(waypoints: Int)
    case dwell(minutes: Int)
    case exitDelay(minutes: Int)
    case passThrough

    nonisolated var text: String {
        switch self {
        case .note: return String(localized: "Memo")
        case .checklist(let n): return String(format: String(localized: "Checklist (%d)"), n)
        case .photo: return String(localized: "Photo")
        case .color: return String(localized: "Color")
        case .tags(let n): return String(format: String(localized: "Tags (%d)"), n)
        case .expiry: return String(localized: "Expiry")
        case .timeWindow(let s, let e):
            return String(format: String(localized: "Time %@"), "\(Self.clock(s))–\(Self.clock(e))")
        case .days(let n): return String(format: String(localized: "Days (%d)"), n)
        case .route(let n): return String(format: String(localized: "Route (%d)"), n)
        case .dwell(let m): return String(format: String(localized: "Dwell %d min"), m)
        case .exitDelay(let m): return String(format: String(localized: "Exit delay %d min"), m)
        case .passThrough: return String(localized: "Pass-through")
        }
    }

    nonisolated static func clock(_ minutes: Int) -> String {
        let m = min(max(minutes, 0), 1439)
        return String(format: "%d:%02d", m / 60, m % 60)
    }
}

/// 編集画面の状態のうち、「詳細」の要約に必要な値。
nonisolated struct MemoAdvancedState: Equatable, Sendable {
    var note: String = ""
    var isListMode = false
    var listItemCount = 0
    var hasPhoto = false
    var colorIndex = 0
    var tagCount = 0
    var hasDeadline = false
    var timeWindow: (start: Int, end: Int)? = nil
    var activeDayCount: Int? = nil
    var isRouteTrigger = false
    var waypointCount = 0
    var notifyOnEntry = true
    var notifyOnExit = true
    var dwellMinutes: Int? = nil
    var exitDelayMinutes: Int? = nil
    var notifyOnPass = false

    nonisolated static func == (a: MemoAdvancedState, b: MemoAdvancedState) -> Bool {
        a.note == b.note && a.isListMode == b.isListMode && a.listItemCount == b.listItemCount
            && a.hasPhoto == b.hasPhoto && a.colorIndex == b.colorIndex && a.tagCount == b.tagCount
            && a.hasDeadline == b.hasDeadline && a.timeWindow?.start == b.timeWindow?.start
            && a.timeWindow?.end == b.timeWindow?.end && a.activeDayCount == b.activeDayCount
            && a.isRouteTrigger == b.isRouteTrigger && a.waypointCount == b.waypointCount
            && a.notifyOnEntry == b.notifyOnEntry && a.notifyOnExit == b.notifyOnExit
            && a.dwellMinutes == b.dwellMinutes && a.exitDelayMinutes == b.exitDelayMinutes
            && a.notifyOnPass == b.notifyOnPass
    }
}

nonisolated enum MemoAdvancedSummary {
    /// 設定済みの項目を、画面の並び順で返す。保存時に効かない設定 (ルート中の到着・退出の遅延など) は数えない。
    nonisolated static func items(for s: MemoAdvancedState) -> [MemoAdvancedItem] {
        var result: [MemoAdvancedItem] = []
        if s.isListMode {
            if s.listItemCount > 0 { result.append(.checklist(count: s.listItemCount)) }
        } else if !s.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.note)
        }
        if s.hasPhoto { result.append(.photo) }
        if s.colorIndex != 0 { result.append(.color) }
        if s.tagCount > 0 { result.append(.tags(count: s.tagCount)) }
        if s.isRouteTrigger { result.append(.route(waypoints: s.waypointCount)) }
        if !s.isRouteTrigger {
            if s.notifyOnEntry, let m = s.dwellMinutes { result.append(.dwell(minutes: m)) }
            if s.notifyOnExit, let m = s.exitDelayMinutes { result.append(.exitDelay(minutes: m)) }
            if s.notifyOnPass { result.append(.passThrough) }
        }
        if s.hasDeadline { result.append(.expiry) }
        if let w = s.timeWindow { result.append(.timeWindow(startMinutes: w.start, endMinutes: w.end)) }
        if let n = s.activeDayCount { result.append(.days(count: n)) }
        return result
    }

    nonisolated static func text(for items: [MemoAdvancedItem]) -> String {
        ListFormatter.localizedString(byJoining: items.map(\.text))
    }
}

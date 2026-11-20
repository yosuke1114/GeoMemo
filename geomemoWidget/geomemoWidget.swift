import WidgetKit
import SwiftUI
import SwiftData
import AppIntents

// MARK: - Shared ModelContainer

private let appGroupID = "group.com.yokuro.geomemo"

private func makeSharedContainer() -> ModelContainer? {
    let schema = Schema([GeoMemo.self])

    if let url = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
        .appendingPathComponent("geomemo.store") {
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try? ModelContainer(for: schema, configurations: [config])
    }

    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
    return try? ModelContainer(for: schema, configurations: [config])
}

// MARK: - Deep Link Constants

/// `geomemoApp.deepLinkScheme` / `DeepLinkHost` と同期した widget 側の定数。
/// （Widget 拡張は別ターゲットなのでアプリ側の static を直接参照できない）
enum WidgetDeepLink {
    static let scheme = "geomemo"
    static let memoHost = "memo"
    /// 新しいメモを作る（`DeepLinkRoute.Host.new` と同じ）。
    static let newHost = "new"
    static let newMemoURL = URL(string: "\(scheme)://\(newHost)")!
    /// memos が空の時の Link 用フォールバック URL。`URL(string:)!` の force-unwrap を
    /// 1 箇所に閉じ込めるための定数（"geomemo://" は常に valid な URL）。
    static let fallback = URL(string: "\(scheme)://")!
}

// MARK: - Timeline Entry

struct MemoEntry: TimelineEntry {
    let date: Date
    let memos: [MemoSnapshot]
    /// 未完了のメモの件数（ロック画面ウィジェット用）。メモの題や場所名は出さず、この数だけを出す。
    var activeCount: Int = 0

    struct MemoSnapshot {
        let id: UUID
        let title: String
        let note: String
        let locationName: String
        let colorIndex: Int
        let isFavorite: Bool
        let tags: [Int]
        let customTags: [String]
        let deadline: Date?
        let routeCurrentWaypoint: Int?
        let routeTotalWaypoints: Int?

        /// Widget タップ時のディープリンク URL。
        /// scheme/host は geomemoApp.deepLinkScheme / DeepLinkHost.memo と一致させること。
        var deepLinkURL: URL? {
            URL(string: "\(WidgetDeepLink.scheme)://\(WidgetDeepLink.memoHost)/\(id.uuidString)")
        }

        var isRouteInProgress: Bool { routeCurrentWaypoint != nil }

        /// 24時間以内に期限が来る
        var hasUrgentDeadline: Bool {
            guard let deadline else { return false }
            let secs = deadline.timeIntervalSinceNow
            return secs > 0 && secs <= 86400
        }

        /// 72時間以内に期限が来る
        var hasUpcomingDeadline: Bool {
            guard let deadline else { return false }
            let secs = deadline.timeIntervalSinceNow
            return secs > 0 && secs <= 259200
        }

        /// 期限バッジ文字列。24h以内→"Xh"/"Xm"、72h以内→曜日+時刻
        var deadlineBadgeText: String? {
            guard let deadline else { return nil }
            let secs = deadline.timeIntervalSinceNow
            guard secs > 0 else { return nil }
            if secs <= 3600 {
                return "\(max(1, Int(secs / 60)))m"
            } else if secs <= 86400 {
                return "\(Int(secs / 3600))h"
            } else if secs <= 259200 {
                return Self.weekdayHourFormatter.string(from: deadline)
            }
            return nil
        }

        /// 毎回 DateFormatter を生成すると widget の per-row レンダリングで GC 負荷が高いため
        /// ファイルスコープで一度だけ生成して再利用する。
        private static let weekdayHourFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "E h a"
            return f
        }()

        var firstTagLabel: String? {
            if let tagId = tags.first, let tag = PresetTag(rawValue: tagId) {
                return tag.localizedName
            }
            return customTags.first
        }
    }

    static let placeholder = MemoEntry(
        date: .now,
        memos: [
            MemoSnapshot(id: UUID(), title: "Corner Coffee", note: "The espresso here is perfect", locationName: "SHIBUYA, TOKYO", colorIndex: 0, isFavorite: false, tags: [2], customTags: [], deadline: Date().addingTimeInterval(7200), routeCurrentWaypoint: nil, routeTotalWaypoints: nil),
            MemoSnapshot(id: UUID(), title: "Bookstore Find", note: "Check the second floor shelves", locationName: "SHIMOKITAZAWA", colorIndex: 1, isFavorite: true, tags: [8], customTags: [], deadline: nil, routeCurrentWaypoint: nil, routeTotalWaypoints: nil),
            MemoSnapshot(id: UUID(), title: "Park Bench Note", note: "Great spot to read on weekends", locationName: "YOYOGI PARK", colorIndex: 3, isFavorite: false, tags: [], customTags: [], deadline: nil, routeCurrentWaypoint: nil, routeTotalWaypoints: nil),
            MemoSnapshot(id: UUID(), title: "Train Station", note: "Exit B2 for the shortcut", locationName: "SHINJUKU", colorIndex: 2, isFavorite: false, tags: [7], customTags: [], deadline: nil, routeCurrentWaypoint: nil, routeTotalWaypoints: nil),
            MemoSnapshot(id: UUID(), title: "Lunch Spot", note: "Set meal is best value here", locationName: "HARAJUKU", colorIndex: 4, isFavorite: true, tags: [3], customTags: [], deadline: nil, routeCurrentWaypoint: nil, routeTotalWaypoints: nil),
        ],
        activeCount: 5
    )

    static let empty = MemoEntry(date: .now, memos: [])
}

// MARK: - Timeline Provider

struct GeoMemoProvider: TimelineProvider {
    func placeholder(in context: Context) -> MemoEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (MemoEntry) -> Void) {
        completion(context.isPreview ? .placeholder : fetchEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoEntry>) -> Void) {
        let base = fetchEntry()
        let now = Date.now

        // 30 分刻みで複数 entry を emit する。各 entry の date は将来時刻で、Widget
        // はそのタイミングで view を再評価するので deadlineBadgeText の "Xm/Xh" 表記が
        // 自動的に最新化される（1 entry 固定だと 30 分以上ステイルになっていた）。
        // 期限 24h/72h の閾値通過時刻も明示的に追加して、しきい値前後の表示崩れを抑える。
        let stride: TimeInterval = 30 * 60
        var dates: [Date] = (0...6).map { now.addingTimeInterval(stride * Double($0)) }
        let thresholds: [TimeInterval] = [3600, 86400, 259200]  // 1h / 24h / 72h
        let checkpoints = base.memos.compactMap { $0.deadline }.flatMap { deadline in
            thresholds.map { deadline.addingTimeInterval(-$0) }.filter { $0 > now && $0 < dates.last! }
        }
        dates.append(contentsOf: checkpoints)
        dates.sort()

        let entries = dates.map { MemoEntry(date: $0, memos: base.memos, activeCount: base.activeCount) }
        // 最後の entry 時刻で再フェッチを依頼（メモ追加/削除を反映）。
        completion(Timeline(entries: entries, policy: .after(dates.last ?? now.addingTimeInterval(1800))))
    }

    private func fetchEntry() -> MemoEntry {
        guard let container = makeSharedContainer() else { return .empty }
        let context = ModelContext(container)

        let routeProgressDict = UserDefaults.standard.object(forKey: "routeProgress") as? [String: Int] ?? [:]
        let routeCountsDict   = UserDefaults.standard.object(forKey: "routeWaypointCounts") as? [String: Int] ?? [:]

        // 完了済みを除外して取得（スマートソート後に3件に絞るため多めに取る）
        var descriptor = FetchDescriptor<GeoMemo>(
            predicate: #Predicate { !$0.isDone },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 20

        guard let fetched = try? context.fetch(descriptor) else { return .empty }

        // ウィジェットの「完了」は拡張のプロセスでは保存せず、完了待ちに積むだけ（`WidgetCompletion.swift`）。
        // アプリが保存するまでの間も、押した行がすぐ消えるよう、完了待ちを除いて描く。
        let pending = WidgetCompletionQueue.shared.pending()
        let memos = fetched.filter { !pending.contains($0.id) }

        // 未完了の件数（20 件で切らない）。完了待ちのうち、まだ保存上は未完了のものを引く。
        let storedActive = (try? context.fetchCount(FetchDescriptor<GeoMemo>(predicate: #Predicate { !$0.isDone }))) ?? memos.count
        let pendingActive: Int
        if pending.isEmpty {
            pendingActive = 0
        } else {
            let ids = Array(pending)
            pendingActive = (try? context.fetchCount(FetchDescriptor<GeoMemo>(
                predicate: #Predicate { !$0.isDone && ids.contains($0.id) }))) ?? 0
        }
        let activeCount = max(0, storedActive - pendingActive)

        let snapshots = memos.map { memo -> MemoEntry.MemoSnapshot in
            let memoID = memo.id.uuidString
            let nextWP = routeProgressDict[memoID]
            let total  = routeCountsDict[memoID]
            return MemoEntry.MemoSnapshot(
                id: memo.id,
                title: memo.title,
                note: memo.note,
                locationName: memo.locationName,
                colorIndex: memo.colorIndex,
                isFavorite: memo.isFavorite,
                tags: memo.tags,
                customTags: memo.customTags,
                deadline: memo.deadline,
                routeCurrentWaypoint: nextWP.map { $0 + 1 },
                routeTotalWaypoints: total
            )
        }
        // スマートソート: ルート進行中 > 期限24h以内 > 期限72h以内 > お気に入り > 新着順
        .sorted { a, b in
            if a.isRouteInProgress   != b.isRouteInProgress   { return a.isRouteInProgress }
            if a.hasUrgentDeadline   != b.hasUrgentDeadline   { return a.hasUrgentDeadline }
            if a.hasUpcomingDeadline != b.hasUpcomingDeadline { return a.hasUpcomingDeadline }
            if a.isFavorite          != b.isFavorite          { return a.isFavorite }
            return false
        }

        return MemoEntry(date: .now, memos: Array(snapshots.prefix(5)), activeCount: activeCount)
    }
}

// MARK: - Memo Row Badge

/// Medium/Large widget の各行で出すサブ情報。route progress > deadline > tag の優先順。
/// 両 widget で同一ロジックだったので 1 箇所にまとめる。
private struct MemoRowBadge: View {
    let memo: MemoEntry.MemoSnapshot
    /// タグラベルだけ Medium/Large でフォントサイズが微妙に違う（10pt vs 9pt）。
    var tagLabelSize: CGFloat = 10

    var body: some View {
        if let cur = memo.routeCurrentWaypoint, let tot = memo.routeTotalWaypoints {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.turn.up.right.circle")
                    .font(.system(size: 8))
                Text("WP \(cur)/\(tot)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Brand.blue)
        } else if let badge = memo.deadlineBadgeText {
            HStack(spacing: 2) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 8))
                Text(badge)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(memo.hasUrgentDeadline ? Color(hex: "E5484D") : Color.orange)
        } else if let tagLabel = memo.firstTagLabel {
            Text(tagLabel)
                .font(.system(size: tagLabelSize, weight: .medium))
                .foregroundStyle(Brand.blue)
        }
    }
}

/// Medium/Large widget の行末アイコン（ルート進行 > 期限 > お気に入り）。
private struct MemoRowTrailingIcon: View {
    let memo: MemoEntry.MemoSnapshot
    var primarySize: CGFloat = 10
    var favoriteSize: CGFloat = 9

    var body: some View {
        if memo.isRouteInProgress {
            Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                .font(.system(size: primarySize))
                .foregroundStyle(Brand.blue)
        } else if memo.hasUrgentDeadline {
            Image(systemName: "clock.fill")
                .font(.system(size: primarySize))
                .foregroundStyle(Color(hex: "E5484D"))
        } else if memo.isFavorite {
            Image(systemName: "heart.fill")
                .font(.system(size: favoriteSize))
                .foregroundStyle(Color(hex: "E5484D"))
        }
    }
}

// MARK: - Done Button

/// 行の右端の「完了」ボタン（インタラクティブ ウィジェット）。押すとアプリを開かずに完了にできる。
private struct DoneButton: View {
    let memoID: UUID
    var iconSize: CGFloat = 20

    var body: some View {
        Button(intent: CompleteMemoFromWidgetIntent(memoID: memoID)) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(Brand.blue)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Complete Memo"))
    }
}

// MARK: - Deadline Badge View

private struct DeadlineBadge: View {
    let text: String
    let urgent: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.fill")
                .font(.system(size: 8))
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(urgent ? Color(hex: "E5484D") : Color.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((urgent ? Color(hex: "E5484D") : Color.orange).opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Small Widget View

struct SmallWidgetView: View {
    let entry: MemoEntry

    var body: some View {
        if let memo = entry.memos.first {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("GeoMemo")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Brand.blue)
                    Spacer()
                    if memo.isRouteInProgress {
                        Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Brand.blue)
                    } else if memo.hasUrgentDeadline {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: "E5484D"))
                    } else if memo.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hex: "E5484D"))
                    }
                    DoneButton(memoID: memo.id, iconSize: 18)
                        .padding(.trailing, -6)
                }

                Spacer()

                HStack(spacing: 5) {
                    if memo.colorIndex != 0 {
                        Circle()
                            .fill(MemoColor(rawValue: memo.colorIndex)?.color ?? Brand.blue)
                            .frame(width: 8, height: 8)
                    }
                    Text(memo.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Brand.primaryText)
                        .lineLimit(2)
                }

                if !memo.locationName.isEmpty {
                    Text(memo.locationName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(1)
                }

                // ルート進行中 > 期限バッジ > タグ の優先順
                if let cur = memo.routeCurrentWaypoint, let tot = memo.routeTotalWaypoints {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.turn.up.right.circle")
                            .font(.system(size: 9))
                        Text("WP \(cur)/\(tot)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(Brand.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Brand.blue.opacity(0.12))
                    .clipShape(Capsule())
                } else if let badge = memo.deadlineBadgeText {
                    DeadlineBadge(text: badge, urgent: memo.hasUrgentDeadline)
                } else if let tagLabel = memo.firstTagLabel {
                    Text(tagLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Brand.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Brand.blue.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 8) {
                Text("GeoMemo")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.blue)
                Text(String(localized: "No memos"))
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.secondaryText)
            }
        }
    }
}

// MARK: - Medium Widget View

struct MediumWidgetView: View {
    let entry: MemoEntry

    var body: some View {
        if entry.memos.isEmpty {
            VStack(spacing: 8) {
                Text("GeoMemo")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.blue)
                Text(String(localized: "No memos"))
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.secondaryText)
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("GeoMemo")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Brand.blue)
                    .padding(.bottom, 6)

                ForEach(Array(entry.memos.prefix(3).enumerated()), id: \.offset) { index, memo in
                    // 行の本体は Link で個別の memo へディープリンクし、右端に「完了」ボタンを並べる。
                    HStack(spacing: 0) {
                    Link(destination: memo.deepLinkURL ?? WidgetDeepLink.fallback) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(MemoColor(rawValue: memo.colorIndex)?.color ?? Brand.blue)
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(memo.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Brand.primaryText)
                                    .lineLimit(1)
                                MemoRowBadge(memo: memo, tagLabelSize: 10)
                            }

                            MemoRowTrailingIcon(memo: memo, primarySize: 10, favoriteSize: 9)

                            Spacer()

                            if !memo.locationName.isEmpty {
                                Text(memo.locationName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Brand.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 5)
                        .background(
                            memo.hasUrgentDeadline ? Color(hex: "E5484D").opacity(0.05) :
                            memo.isRouteInProgress ? Brand.blue.opacity(0.05) : Color.clear
                        )
                    }
                    DoneButton(memoID: memo.id, iconSize: 18)
                    }

                    if index < entry.memos.prefix(3).count - 1 {
                        Divider()
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Large Widget View

struct LargeWidgetView: View {
    let entry: MemoEntry

    var body: some View {
        if entry.memos.isEmpty {
            VStack(spacing: 8) {
                Text("GeoMemo")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Brand.blue)
                Text(String(localized: "No memos"))
                    .font(.system(size: 14))
                    .foregroundStyle(Brand.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("GeoMemo")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Brand.blue)
                    .padding(.bottom, 8)

                ForEach(Array(entry.memos.prefix(5).enumerated()), id: \.offset) { index, memo in
                    // 行の本体は Link で個別の memo へディープリンクし、右端に「完了」ボタンを並べる。
                    HStack(spacing: 0) {
                    Link(destination: memo.deepLinkURL ?? WidgetDeepLink.fallback) {
                        HStack(alignment: .top, spacing: 10) {
                            // カラードット
                            Circle()
                                .fill(MemoColor(rawValue: memo.colorIndex)?.color ?? Brand.blue)
                                .frame(width: 9, height: 9)
                                .padding(.top, 4)

                            VStack(alignment: .leading, spacing: 3) {
                                // タイトル行
                                HStack(spacing: 4) {
                                    Text(memo.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Brand.primaryText)
                                        .lineLimit(1)

                                    Spacer()

                                    MemoRowTrailingIcon(memo: memo, primarySize: 11, favoriteSize: 10)

                                    if !memo.locationName.isEmpty {
                                        Text(memo.locationName)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Brand.secondaryText)
                                            .lineLimit(1)
                                    }
                                }

                                // ノートプレビュー
                                if !memo.note.isEmpty {
                                    Text(memo.note)
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundStyle(Brand.secondaryText)
                                        .lineLimit(1)
                                }

                                MemoRowBadge(memo: memo, tagLabelSize: 9)
                            }
                        }
                        .padding(.vertical, 6)
                        .background(
                            memo.hasUrgentDeadline ? Color(hex: "E5484D").opacity(0.05) :
                            memo.isRouteInProgress  ? Brand.blue.opacity(0.05) : Color.clear
                        )
                    }
                    DoneButton(memoID: memo.id, iconSize: 20)
                    }

                    if index < entry.memos.prefix(5).count - 1 {
                        Divider()
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Lock Screen (accessory) Views
//
// プライバシー: ロック画面は端末を持たない人にも見える。メモの題・場所名・メモの位置は出さず、
// 未完了の件数だけを出す（件数も `privacySensitive` にして、ロック中は伏せられる設定に従わせる）。
// 「近い順」は端末の位置を使わないと決まらないので扱わない。タップはアプリを開く。

private struct AccessoryCircularView: View {
    let entry: MemoEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(entry.activeCount)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .privacySensitive()
            }
        }
        .widgetAccentable()
        // 円形はコントロールのように使えるよう、タップで「新しいメモ」を開く。
        .widgetURL(WidgetDeepLink.newMemoURL)
    }
}

private struct AccessoryRectangularView: View {
    let entry: MemoEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("GeoMemo", systemImage: "mappin.and.ellipse")
                .font(.headline)
                .widgetAccentable()
            if entry.activeCount > 0 {
                Text("\(entry.activeCount) memos active")
                    .font(.system(size: 13, weight: .medium))
                    .privacySensitive()
            } else {
                Text("No memos")
                    .font(.system(size: 13, weight: .medium))
            }
            Text("Tap to open")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccessoryInlineView: View {
    let entry: MemoEntry

    var body: some View {
        if entry.activeCount > 0 {
            Label {
                Text("\(entry.activeCount) memos active")
                    .privacySensitive()
            } icon: {
                Image(systemName: "mappin.and.ellipse")
            }
        } else {
            Label("GeoMemo", systemImage: "mappin.and.ellipse")
        }
    }
}

// MARK: - Widget Definition

struct geomemoWidget: Widget {
    let kind: String = "geomemoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GeoMemoProvider()) { entry in
            GeoMemoWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("GeoMemo")
        .description("Shows your most important memos")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

/// Widget の root view。`@Environment(\.widgetFamily)` で正確な family を判定する。
/// GeometryReader の width 推定は端末サイズで誤判定するため使わない。
private struct GeoMemoWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MemoEntry

    private var isAccessory: Bool {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: true
        default: false
        }
    }

    var body: some View {
        Group {
            switch family {
            case .systemLarge:  LargeWidgetView(entry: entry)
            case .systemMedium: MediumWidgetView(entry: entry)
            case .accessoryCircular:    AccessoryCircularView(entry: entry)
            case .accessoryRectangular: AccessoryRectangularView(entry: entry)
            case .accessoryInline:      AccessoryInlineView(entry: entry)
            default:            SmallWidgetView(entry: entry)
            }
        }
        .containerBackground(for: .widget) {
            if isAccessory { Color.clear } else { Brand.background }
        }
        // Widget タップでトップメモへディープリンク。memos が空ならアプリ既定画面が開く。
        // Medium/Large は個別 row の Link が優先され、それ以外の余白タップでこちらが効く。
        // ロック画面（accessory）では題を出さないので、メモへの直接リンクにはしない（円形だけ別に指定）。
        .widgetURL(isAccessory ? nil : entry.memos.first?.deepLinkURL)
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    geomemoWidget()
} timeline: {
    MemoEntry.placeholder
}

#Preview(as: .systemMedium) {
    geomemoWidget()
} timeline: {
    MemoEntry.placeholder
}

#Preview(as: .systemLarge) {
    geomemoWidget()
} timeline: {
    MemoEntry.placeholder
}

#Preview(as: .accessoryRectangular) {
    geomemoWidget()
} timeline: {
    MemoEntry.placeholder
}

#Preview(as: .accessoryCircular) {
    geomemoWidget()
} timeline: {
    MemoEntry.placeholder
}

#Preview(as: .accessoryInline) {
    geomemoWidget()
} timeline: {
    MemoEntry.placeholder
}

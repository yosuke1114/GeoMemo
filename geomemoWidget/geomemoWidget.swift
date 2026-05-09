import WidgetKit
import SwiftUI
import SwiftData

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

// MARK: - Timeline Entry

struct MemoEntry: TimelineEntry {
    let date: Date
    let memos: [MemoSnapshot]

    struct MemoSnapshot {
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
                let f = DateFormatter()
                f.dateFormat = "E h a"
                return f.string(from: deadline)
            }
            return nil
        }

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
            MemoSnapshot(title: "Corner Coffee", note: "The espresso here is perfect", locationName: "SHIBUYA, TOKYO", colorIndex: 0, isFavorite: false, tags: [2], customTags: [], deadline: Date().addingTimeInterval(7200), routeCurrentWaypoint: nil, routeTotalWaypoints: nil),
            MemoSnapshot(title: "Bookstore Find", note: "Check the second floor shelves", locationName: "SHIMOKITAZAWA", colorIndex: 1, isFavorite: true, tags: [8], customTags: [], deadline: nil, routeCurrentWaypoint: nil, routeTotalWaypoints: nil),
            MemoSnapshot(title: "Park Bench Note", note: "Great spot to read on weekends", locationName: "YOYOGI PARK", colorIndex: 3, isFavorite: false, tags: [], customTags: [], deadline: nil, routeCurrentWaypoint: nil, routeTotalWaypoints: nil),
            MemoSnapshot(title: "Train Station", note: "Exit B2 for the shortcut", locationName: "SHINJUKU", colorIndex: 2, isFavorite: false, tags: [7], customTags: [], deadline: nil, routeCurrentWaypoint: nil, routeTotalWaypoints: nil),
            MemoSnapshot(title: "Lunch Spot", note: "Set meal is best value here", locationName: "HARAJUKU", colorIndex: 4, isFavorite: true, tags: [3], customTags: [], deadline: nil, routeCurrentWaypoint: nil, routeTotalWaypoints: nil),
        ]
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
        let entry = fetchEntry()

        // 期限の 24h/72h 閾値通過タイミングで更新。それ以外は30分ごと
        let now = Date.now
        let thresholds: [TimeInterval] = [86400, 259200]  // 24h, 72h
        let checkpoints = entry.memos.compactMap { $0.deadline }.flatMap { deadline in
            thresholds.map { deadline.addingTimeInterval(-$0) }.filter { $0 > now }
        }
        let default30min = Calendar.current.date(byAdding: .minute, value: 30, to: now)!
        let nextUpdate = ([default30min] + checkpoints).min()!

        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
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

        guard let memos = try? context.fetch(descriptor) else { return .empty }

        let snapshots = memos.map { memo -> MemoEntry.MemoSnapshot in
            let memoID = memo.id.uuidString
            let nextWP = routeProgressDict[memoID]
            let total  = routeCountsDict[memoID]
            return MemoEntry.MemoSnapshot(
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

        return MemoEntry(date: .now, memos: Array(snapshots.prefix(5)))
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
                    HStack(spacing: 6) {
                        Circle()
                            .fill(MemoColor(rawValue: memo.colorIndex)?.color ?? Brand.blue)
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(memo.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Brand.primaryText)
                                .lineLimit(1)
                            // ルート進行中 > 期限バッジ > タグ の優先順
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
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Brand.blue)
                            }
                        }

                        if memo.isRouteInProgress {
                            Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Brand.blue)
                        } else if memo.hasUrgentDeadline {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(hex: "E5484D"))
                        } else if memo.isFavorite {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(hex: "E5484D"))
                        }

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

                            // ルート進行中 > 期限バッジ > タグ の優先順
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
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Brand.blue)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .background(
                        memo.hasUrgentDeadline ? Color(hex: "E5484D").opacity(0.05) :
                        memo.isRouteInProgress  ? Brand.blue.opacity(0.05) : Color.clear
                    )

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

// MARK: - Widget Definition

struct geomemoWidget: Widget {
    let kind: String = "geomemoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GeoMemoProvider()) { entry in
            GeometryReader { geo in
                if geo.size.width > 200 && geo.size.height > 200 {
                    LargeWidgetView(entry: entry)
                } else if geo.size.width > 200 {
                    MediumWidgetView(entry: entry)
                } else {
                    SmallWidgetView(entry: entry)
                }
            }
            .containerBackground(Brand.background, for: .widget)
        }
        .configurationDisplayName("GeoMemo")
        .description("Shows your most important memos")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
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

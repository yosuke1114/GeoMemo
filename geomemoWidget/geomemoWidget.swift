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
        let locationName: String
        let colorIndex: Int
        let isFavorite: Bool
        let tags: [Int]
        let customTags: [String]
        /// ルートトリガーが進行中（次のウェイポイントを待っている状態）
        let routeCurrentWaypoint: Int?
        let routeTotalWaypoints: Int?

        var isRouteInProgress: Bool { routeCurrentWaypoint != nil }

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
            MemoSnapshot(title: "Corner Coffee", locationName: "SHIBUYA, TOKYO", colorIndex: 0, isFavorite: false, tags: [2], customTags: [], routeCurrentWaypoint: nil, routeTotalWaypoints: nil),
            MemoSnapshot(title: "Bookstore Find", locationName: "SHIMOKITAZAWA", colorIndex: 1, isFavorite: true, tags: [8], customTags: [], routeCurrentWaypoint: nil, routeTotalWaypoints: nil),
            MemoSnapshot(title: "Park Bench Note", locationName: "YOYOGI PARK", colorIndex: 3, isFavorite: false, tags: [], customTags: [], routeCurrentWaypoint: nil, routeTotalWaypoints: nil),
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
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func fetchEntry() -> MemoEntry {
        guard let container = makeSharedContainer() else { return .empty }
        let context = ModelContext(container)

        // ルート進行状況を UserDefaults から読み込む
        let routeProgressDict = UserDefaults.standard.object(forKey: "routeProgress") as? [String: Int] ?? [:]
        let routeCountsDict   = UserDefaults.standard.object(forKey: "routeWaypointCounts") as? [String: Int] ?? [:]

        // 完了済みを除外して取得（上限を多めに取り、進行中優先ソート後に3件に絞る）
        var descriptor = FetchDescriptor<GeoMemo>(
            predicate: #Predicate { !$0.isDone },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 10

        guard let memos = try? context.fetch(descriptor) else { return .empty }

        let snapshots: [MemoEntry.MemoSnapshot] = memos.map { memo in
            let memoID = memo.id.uuidString
            let nextWP = routeProgressDict[memoID]
            let total  = routeCountsDict[memoID]
            let currentDisplay = (nextWP != nil) ? (nextWP! + 1) : nil

            return MemoEntry.MemoSnapshot(
                title: memo.title,
                locationName: memo.locationName,
                colorIndex: memo.colorIndex,
                isFavorite: memo.isFavorite,
                tags: memo.tags,
                customTags: memo.customTags,
                routeCurrentWaypoint: currentDisplay,
                routeTotalWaypoints: total
            )
        }
        // ルート進行中のメモを先頭に並べ、最大3件
        .sorted { $0.isRouteInProgress && !$1.isRouteInProgress }

        return MemoEntry(date: .now, memos: Array(snapshots.prefix(3)))
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

                // ルート進行中バッジ or タグ
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
                Text("No memos")
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
                Text("No memos")
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

                ForEach(Array(entry.memos.prefix(3).enumerated()), id: \.offset) { _, memo in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(MemoColor(rawValue: memo.colorIndex)?.color ?? Brand.blue)
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(memo.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Brand.primaryText)
                                .lineLimit(1)
                            // ルート進行中バッジ or タグ
                            if let cur = memo.routeCurrentWaypoint, let tot = memo.routeTotalWaypoints {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.triangle.turn.up.right.circle")
                                        .font(.system(size: 8))
                                    Text("WP \(cur)/\(tot)")
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                }
                                .foregroundStyle(Brand.blue)
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
                    .background(memo.isRouteInProgress ? Brand.blue.opacity(0.05) : Color.clear)

                    if memo.title != entry.memos.prefix(3).last?.title {
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
            Group {
                switch entry.memos.count {
                default:
                    GeometryReader { geo in
                        if geo.size.width > 200 {
                            MediumWidgetView(entry: entry)
                        } else {
                            SmallWidgetView(entry: entry)
                        }
                    }
                }
            }
            .containerBackground(Brand.background, for: .widget)
        }
        .configurationDisplayName("GeoMemo")
        .description("Shows your latest memos")
        .supportedFamilies([.systemSmall, .systemMedium])
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

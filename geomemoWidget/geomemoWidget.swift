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
    }

    static let placeholder = MemoEntry(
        date: .now,
        memos: [
            MemoSnapshot(title: "Corner Coffee", locationName: "SHIBUYA, TOKYO", colorIndex: 0, isFavorite: false),
            MemoSnapshot(title: "Bookstore Find", locationName: "SHIMOKITAZAWA", colorIndex: 1, isFavorite: true),
            MemoSnapshot(title: "Park Bench Note", locationName: "YOYOGI PARK", colorIndex: 3, isFavorite: false),
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

        var descriptor = FetchDescriptor<GeoMemo>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 3

        guard let memos = try? context.fetch(descriptor) else { return .empty }

        let snapshots = memos.map { memo in
            MemoEntry.MemoSnapshot(
                title: memo.title,
                locationName: memo.locationName,
                colorIndex: memo.colorIndex,
                isFavorite: memo.isFavorite
            )
        }

        return MemoEntry(date: .now, memos: snapshots)
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
                    if memo.isFavorite {
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

                        Text(memo.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Brand.primaryText)
                            .lineLimit(1)

                        if memo.isFavorite {
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

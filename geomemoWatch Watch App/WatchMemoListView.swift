import SwiftUI
import SwiftData

struct WatchMemoListView: View {
    @Query(sort: \GeoMemo.createdAt, order: .reverse) private var allMemos: [GeoMemo]
    @Environment(\.modelContext) private var modelContext
    @State private var showDeleteConfirm = false
    @State private var memoToDelete: GeoMemo?

    private var memos: [GeoMemo] { allMemos.filter { !$0.isDone } }
    private var doneMemos: [GeoMemo] { allMemos.filter { $0.isDone } }

    var body: some View {
        NavigationStack {
            Group {
                if memos.isEmpty && doneMemos.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "mappin.slash")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No memos")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        ForEach(memos) { memo in
                            NavigationLink(value: memo.id) {
                                MemoRow(memo: memo)
                            }
                        }
                        .onDelete { indexSet in
                            if let index = indexSet.first {
                                memoToDelete = memos[index]
                                showDeleteConfirm = true
                            }
                        }

                        if !doneMemos.isEmpty {
                            Section(String(localized: "Complete (\(doneMemos.count))")) {
                                ForEach(doneMemos) { memo in
                                    NavigationLink(value: memo.id) {
                                        MemoRow(memo: memo, isDone: true)
                                    }
                                }
                                .onDelete { indexSet in
                                    if let index = indexSet.first {
                                        memoToDelete = doneMemos[index]
                                        showDeleteConfirm = true
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("GeoMemo")
            .navigationDestination(for: UUID.self) { id in
                if let memo = allMemos.first(where: { $0.id == id }) {
                    WatchMemoDetailView(memo: memo)
                }
            }
            .confirmationDialog("Delete this memo?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    if let memo = memoToDelete {
                        modelContext.delete(memo)
                        try? modelContext.save()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

// MARK: - Memo Row

private struct MemoRow: View {
    let memo: GeoMemo
    var isDone: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isDone
                      ? Color.gray.opacity(0.4)
                      : WatchMemoColor.color(for: memo.colorIndex))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(memo.title.isEmpty ? String(localized: "Untitled") : memo.title)
                    .font(.headline)
                    .lineLimit(1)
                    .strikethrough(isDone)
                    .foregroundStyle(isDone ? .secondary : .primary)

                if !memo.locationName.isEmpty {
                    Text(memo.locationName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else if memo.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

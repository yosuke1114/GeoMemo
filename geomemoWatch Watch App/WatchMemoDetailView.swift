import SwiftUI
import SwiftData

struct WatchMemoDetailView: View {
    @Bindable var memo: GeoMemo
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Color bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(WatchMemoColor.color(for: memo.colorIndex))
                    .frame(height: 4)

                // Title
                Text(memo.title.isEmpty ? String(localized: "Untitled") : memo.title)
                    .font(.headline)

                // Location
                if !memo.locationName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.caption)
                            .foregroundStyle(WatchMemoColor.color(for: memo.colorIndex))
                        Text(memo.locationName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Note
                if !memo.note.isEmpty {
                    Text(memo.note)
                        .font(.body)
                        .foregroundStyle(.primary)
                }

                Divider()

                // Created date
                HStack {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(memo.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Favorite toggle
                Button {
                    memo.isFavorite.toggle()
                    try? modelContext.save()
                } label: {
                    HStack {
                        Image(systemName: memo.isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(memo.isFavorite ? .red : .secondary)
                        Text(memo.isFavorite ? "Remove from favorites" : "Favorite")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)

                // Delete button
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Delete")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.horizontal)
        }
        .navigationTitle(memo.title.isEmpty ? String(localized: "Memo") : memo.title)
        .confirmationDialog("Delete this memo?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                modelContext.delete(memo)
                try? modelContext.save()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

import SwiftUI
import SwiftData
import WatchKit

struct WatchMemoDetailView: View {
    @Bindable var memo: GeoMemo
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var showDoneAnimation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Color bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(memo.isDone ? Color.gray.opacity(0.3) : WatchMemoColor.color(for: memo.colorIndex))
                    .frame(height: 4)

                // Title
                HStack(spacing: 6) {
                    if memo.isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                    Text(memo.title.isEmpty ? String(localized: "Untitled") : memo.title)
                        .font(.headline)
                        .strikethrough(memo.isDone)
                        .foregroundStyle(memo.isDone ? .secondary : .primary)
                }

                // Location
                if !memo.locationName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.caption)
                            .foregroundStyle(memo.isDone ? .secondary : WatchMemoColor.color(for: memo.colorIndex))
                        Text(memo.locationName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Note
                if !memo.note.isEmpty {
                    Text(memo.note)
                        .font(.body)
                        .foregroundStyle(memo.isDone ? .secondary : .primary)
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

                // Complete / Restore button
                Button {
                    if memo.isDone {
                        memo.isDone = false
                        try? modelContext.save()
                        WKInterfaceDevice.current().play(.click)
                    } else {
                        memo.isDone = true
                        showDoneAnimation = true
                        try? modelContext.save()
                        WKInterfaceDevice.current().play(.success)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: memo.isDone ? "arrow.uturn.left" : "checkmark")
                            .foregroundStyle(memo.isDone ? WatchBrand.blue : .green)
                        Text(memo.isDone ? "Restore" : "Complete")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .tint(memo.isDone ? WatchBrand.blue : .green)

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
        .overlay {
            if showDoneAnimation {
                ZStack {
                    Color.black.opacity(0.6)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showDoneAnimation)
    }
}

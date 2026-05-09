import SwiftUI
import SwiftData

struct FavoritePlacesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FavoritePlace.createdAt, order: .forward) private var places: [FavoritePlace]

    @State private var showAddSheet = false
    @State private var editingPlace: FavoritePlace?

    var body: some View {
        NavigationStack {
            Group {
                if places.isEmpty {
                    emptyState
                } else {
                    placesList
                }
            }
            .background(Brand.background)
            .navigationTitle(String(localized: "Favorite Places"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                        .foregroundStyle(Brand.primaryText)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Brand.blue)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            FavoritePlaceEditorView(mode: .add)
        }
        .sheet(item: $editingPlace) { place in
            FavoritePlaceEditorView(mode: .edit(place))
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 48))
                .foregroundStyle(Brand.blue.opacity(0.5))
            Text(String(localized: "No favorite places yet"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Brand.primaryText)
            Text(String(localized: "Save locations you visit often to quickly set them when creating a memo."))
                .font(.system(size: 14))
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showAddSheet = true
            } label: {
                Text(String(localized: "Add Place"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 160, height: 44)
                    .background(Brand.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Places List

    private var placesList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(places) { place in
                    placeRow(place)
                    if place.id != places.last?.id {
                        Rectangle()
                            .fill(Brand.primaryText.opacity(0.1))
                            .frame(height: 1)
                            .padding(.leading, 60)
                    }
                }
            }
            .background(Brand.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 20)
        }
    }

    private func placeRow(_ place: FavoritePlace) -> some View {
        HStack(spacing: 14) {
            Image(systemName: place.iconName)
                .font(.system(size: 18))
                .foregroundStyle(Brand.blue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.primaryText)
                if !place.subtitle.isEmpty {
                    Text(place.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.secondaryText)
                }
            }

            Spacer()

            Button {
                editingPlace = place
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.secondaryText)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                modelContext.delete(place)
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
    }
}

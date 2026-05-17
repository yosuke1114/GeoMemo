import SwiftUI
import SwiftData
import MapKit

struct FavoritePlaceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    enum Mode {
        case add
        case edit(FavoritePlace)
    }

    let mode: Mode

    @State private var name: String = ""
    @State private var subtitle: String = ""
    @State private var latitude: Double = 35.6812
    @State private var longitude: Double = 139.7671
    @State private var iconName: String = "mappin.fill"
    @State private var showLocationPicker = false

    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    init(mode: Mode) {
        self.mode = mode
        if case .edit(let place) = mode {
            _name      = State(initialValue: place.name)
            _subtitle  = State(initialValue: place.subtitle)
            _latitude  = State(initialValue: place.latitude)
            _longitude = State(initialValue: place.longitude)
            _iconName  = State(initialValue: place.iconName)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {

                    // MARK: Icon
                    sectionHeader("ICON")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(favoritePlaceIcons, id: \.systemName) { icon in
                            Button {
                                iconName = icon.systemName
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: icon.systemName)
                                        .font(.title3)
                                        .foregroundStyle(iconName == icon.systemName ? .white : Brand.primaryText)
                                        .frame(width: 44, height: 44)
                                        .background(
                                            iconName == icon.systemName
                                                ? Brand.blue
                                                : Brand.primaryText.opacity(0.07)
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    Text(icon.label)
                                        .font(.caption2)
                                        .foregroundStyle(Brand.secondaryText)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)

                    divider()

                    // MARK: Name
                    sectionHeader("NAME")
                    TextField(String(localized: "e.g. Office, Home, Gym"), text: $name)
                        .font(.body)
                        .foregroundStyle(Brand.primaryText)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)

                    divider()

                    // MARK: Location
                    sectionHeader("LOCATION")
                    Button {
                        showLocationPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.body)
                                .foregroundStyle(Brand.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                if subtitle.isEmpty {
                                    Text(String(localized: "Tap to select location"))
                                        .font(.subheadline)
                                        .foregroundStyle(Brand.secondaryText)
                                } else {
                                    Text(subtitle)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Brand.primaryText)
                                    Text(String(format: "%.4f, %.4f", latitude, longitude))
                                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                                        .foregroundStyle(Brand.secondaryText)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(Brand.secondaryText)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    }

                    divider()
                }
            }
            .background(Brand.background)
            .navigationTitle(mode.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                        .foregroundStyle(Brand.primaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { save() }
                        .foregroundStyle(isValid ? Brand.blue : Brand.secondaryText)
                        .disabled(!isValid)
                }
            }
        }
        .sheet(isPresented: $showLocationPicker) {
            LocationPickerSheetV2(
                initialCoordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                radius: 100,
                showFavorites: false
            ) { coordinate, locationName in
                latitude  = coordinate.latitude
                longitude = coordinate.longitude
                subtitle  = locationName
            }
        }
    }

    // MARK: - Helpers

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        switch mode {
        case .add:
            let place = FavoritePlace(
                name: trimmedName,
                subtitle: subtitle,
                latitude: latitude,
                longitude: longitude,
                iconName: iconName
            )
            modelContext.insert(place)
        case .edit(let place):
            place.name     = trimmedName
            place.subtitle = subtitle
            place.latitude = latitude
            place.longitude = longitude
            place.iconName = iconName
        }
        dismiss()
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Brand.secondaryText)
            .tracking(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 4)
    }

    private func divider() -> some View {
        Rectangle()
            .fill(Brand.primaryText.opacity(0.1))
            .frame(height: 1)
    }
}

extension FavoritePlaceEditorView.Mode {
    var navigationTitle: String {
        switch self {
        case .add:  return String(localized: "Add Place")
        case .edit: return String(localized: "Edit Place")
        }
    }
}

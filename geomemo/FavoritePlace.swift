import Foundation
import SwiftData
import CoreLocation

// MARK: - FavoritePlace Model (v1.4)

@Model final class FavoritePlace: Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var subtitle: String = ""   // 住所・エリア名
    var latitude: Double = 0.0
    var longitude: Double = 0.0
    var iconName: String = "mappin.fill"
    var createdAt: Date = Date()

    init(
        name: String,
        subtitle: String,
        latitude: Double,
        longitude: Double,
        iconName: String = "mappin.fill",
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.iconName = iconName
        self.createdAt = createdAt
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Icon Options

struct FavoritePlaceIcon {
    let systemName: String
    let label: String
}

let favoritePlaceIcons: [FavoritePlaceIcon] = [
    .init(systemName: "mappin.fill",            label: String(localized: "場所")),
    .init(systemName: "house.fill",             label: String(localized: "自宅")),
    .init(systemName: "building.2.fill",        label: String(localized: "職場")),
    .init(systemName: "cup.and.saucer.fill",    label: String(localized: "カフェ")),
    .init(systemName: "fork.knife",             label: String(localized: "飲食")),
    .init(systemName: "cart.fill",              label: String(localized: "買い物")),
    .init(systemName: "train.side.front.car",   label: String(localized: "駅")),
    .init(systemName: "dumbbell.fill",          label: String(localized: "ジム")),
    .init(systemName: "book.fill",              label: String(localized: "本屋")),
    .init(systemName: "heart.fill",             label: String(localized: "その他")),
]

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

    init(name: String, subtitle: String, latitude: Double, longitude: Double, iconName: String = "mappin.fill") {
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.iconName = iconName
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
    .init(systemName: "mappin.fill",            label: "場所"),
    .init(systemName: "house.fill",             label: "自宅"),
    .init(systemName: "building.2.fill",        label: "職場"),
    .init(systemName: "cup.and.saucer.fill",    label: "カフェ"),
    .init(systemName: "fork.knife",             label: "飲食"),
    .init(systemName: "cart.fill",              label: "買い物"),
    .init(systemName: "train.side.front.car",   label: "駅"),
    .init(systemName: "dumbbell.fill",          label: "ジム"),
    .init(systemName: "book.fill",              label: "本屋"),
    .init(systemName: "heart.fill",             label: "その他"),
]

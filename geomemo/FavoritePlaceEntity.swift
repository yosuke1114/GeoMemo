import AppIntents
import SwiftData
import Foundation

// MARK: - 保存済みの場所（お気に入りの場所）を App Intents から選べるようにする

/// ショートカット・Siri の引数に使う「お気に入りの場所」。スキーマは変えず、既存の `FavoritePlace` を写すだけ。
struct FavoritePlaceEntity: AppEntity {
    static let defaultQuery = FavoritePlaceEntityQuery()
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Favorite Place"

    var id: UUID
    var name: String
    var subtitle: String
    var latitude: Double
    var longitude: Double
    var iconName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: subtitle.isEmpty ? nil : "\(subtitle)",
            image: .init(systemName: iconName),
            // 名前を付けていなくても「自宅」「職場」などの呼び名で引けるよう、アイコン由来の別名を渡す
            synonyms: PlaceResolver.aliases(forIcon: iconName).map { LocalizedStringResource(stringLiteral: $0) }
        )
    }

    nonisolated init(from candidate: PlaceCandidate) {
        self.id = candidate.id
        self.name = candidate.name
        self.subtitle = candidate.subtitle
        self.latitude = candidate.latitude
        self.longitude = candidate.longitude
        self.iconName = candidate.iconName
    }

    /// 純粋ロジック（`PlaceResolver`）に渡す形。
    nonisolated var candidate: PlaceCandidate {
        PlaceCandidate(id: id, name: name, subtitle: subtitle,
                       latitude: latitude, longitude: longitude, iconName: iconName)
    }
}

extension PlaceCandidate {
    /// SwiftData のモデルから値型へ写す。モデルを読むのは呼び出し元のコンテキストの中だけにする。
    nonisolated init(_ place: FavoritePlace) {
        self.init(id: place.id, name: place.name, subtitle: place.subtitle,
                  latitude: place.latitude, longitude: place.longitude, iconName: place.iconName)
    }
}

extension GeoMemoStore {
    /// 保存済みの場所（作成順）。App Intents のどのスレッドからでも呼べる。
    nonisolated static func fetchFavoritePlaceCandidates() throws -> [PlaceCandidate] {
        let context = ModelContext(try sharedContainer())
        let places = try context.fetch(FetchDescriptor<FavoritePlace>(sortBy: [SortDescriptor(\.createdAt)]))
        return places.map(PlaceCandidate.init)
    }
}

struct FavoritePlaceEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [FavoritePlaceEntity] {
        let wanted = Set(identifiers)
        return try GeoMemoStore.fetchFavoritePlaceCandidates()
            .filter { wanted.contains($0.id) }
            .map(FavoritePlaceEntity.init(from:))
    }

    func suggestedEntities() async throws -> [FavoritePlaceEntity] {
        try GeoMemoStore.fetchFavoritePlaceCandidates().prefix(20).map(FavoritePlaceEntity.init(from:))
    }

    /// 語から引く（名前・アイコン由来の別名・住所。全角半角・大小文字・ひらがなカタカナの違いは無視）。
    /// 最も強い一致が 1 件ならその 1 件だけを返し、同じ強さで複数あればそれらを返す。
    func entities(matching string: String) async throws -> [FavoritePlaceEntity] {
        switch PlaceResolver.resolve(string, in: try GeoMemoStore.fetchFavoritePlaceCandidates()) {
        case .resolved(let place): return [FavoritePlaceEntity(from: place)]
        case .ambiguous(let places): return places.map(FavoritePlaceEntity.init(from:))
        case .notFound: return []
        }
    }
}

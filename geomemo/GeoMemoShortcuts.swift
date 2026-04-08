import AppIntents

struct GeoMemoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenGeoMemoIntent(),
            phrases: [
                "Open memo in \(.applicationName)",
                "\(.applicationName)でメモを開く"
            ],
            shortTitle: "Open Memo",
            systemImageName: "mappin.and.ellipse"
        )

        AppShortcut(
            intent: ShowFavoritesIntent(),
            phrases: [
                "Show favorites in \(.applicationName)",
                "\(.applicationName)でお気に入りを表示"
            ],
            shortTitle: "Favorites",
            systemImageName: "heart.fill"
        )

        AppShortcut(
            intent: ListNearbyMemosIntent(),
            phrases: [
                "Nearby memos in \(.applicationName)",
                "\(.applicationName)で近くのメモ"
            ],
            shortTitle: "Nearby",
            systemImageName: "location.fill"
        )

        AppShortcut(
            intent: SearchGeoMemosIntent(),
            phrases: [
                "Search \(.applicationName)",
                "\(.applicationName)で検索"
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
    }
}

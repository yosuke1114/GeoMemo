import Foundation

extension GeoMemo {
    /// listItemsData から [ListItem] をデコードして返す。セットするとエンコードして保存する。
    var listItems: [ListItem] {
        get {
            guard let data = listItemsData else { return [] }
            return (try? JSONDecoder().decode([ListItem].self, from: data)) ?? []
        }
        set {
            listItemsData = try? JSONEncoder().encode(newValue)
        }
    }
}

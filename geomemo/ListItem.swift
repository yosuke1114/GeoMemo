import Foundation

struct ListItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var text: String
    var isChecked: Bool = false
}

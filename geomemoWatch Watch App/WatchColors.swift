import SwiftUI

// MARK: - Watch Color Helper (no UIColor dependency)

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

enum WatchMemoColor: Int, CaseIterable {
    case blue = 0, red, amber, green, purple, gray

    var color: Color {
        switch self {
        case .blue:   return Color(hex: "3D3BF3")
        case .red:    return Color(hex: "E5484D")
        case .amber:  return Color(hex: "E5A000")
        case .green:  return Color(hex: "30A46C")
        case .purple: return Color(hex: "8E4EC6")
        case .gray:   return Color.gray
        }
    }

    static func color(for index: Int) -> Color {
        (WatchMemoColor(rawValue: index) ?? .blue).color
    }
}

enum WatchBrand {
    static let blue = Color(hex: "3D3BF3")
}

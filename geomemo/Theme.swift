import SwiftUI
import UIKit

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hexSanitized.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 255, 255, 255)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

// MARK: - Appearance Mode

enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Brand Colors (Adaptive Light/Dark)

enum Brand {
    // Brand accent — same in both modes
    static let blue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x7B/255.0, green: 0x79/255.0, blue: 0xFF/255.0, alpha: 1)
            : UIColor(red: 0x3D/255.0, green: 0x3B/255.0, blue: 0xF3/255.0, alpha: 1)
    })

    // Backgrounds
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x1A/255.0, alpha: 1)
            : .white
    })

    static let secondaryBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x2C/255.0, green: 0x2C/255.0, blue: 0x2E/255.0, alpha: 1)
            : UIColor(red: 0xF5/255.0, green: 0xF5/255.0, blue: 0xF5/255.0, alpha: 1)
    })

    static let tertiaryBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x1C/255.0, green: 0x1C/255.0, blue: 0x1E/255.0, alpha: 1)
            : UIColor(red: 0xF9/255.0, green: 0xF9/255.0, blue: 0xF9/255.0, alpha: 1)
    })

    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x2C/255.0, green: 0x2C/255.0, blue: 0x2E/255.0, alpha: 1)
            : .white
    })

    // Text
    static let primaryText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xF5/255.0, green: 0xF5/255.0, blue: 0xF5/255.0, alpha: 1)
            : UIColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x1A/255.0, alpha: 1)
    })

    static let secondaryText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x98/255.0, green: 0x98/255.0, blue: 0x9D/255.0, alpha: 1)
            : UIColor(red: 0x6E/255.0, green: 0x6E/255.0, blue: 0x73/255.0, alpha: 1)
    })

    static let tertiaryText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.5)
            : UIColor.black.withAlphaComponent(0.5)
    })

    // Structural
    static let separator = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x38/255.0, green: 0x38/255.0, blue: 0x3A/255.0, alpha: 1)
            : UIColor(red: 0xE5/255.0, green: 0xE5/255.0, blue: 0xEA/255.0, alpha: 1)
    })

    static let border = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x48/255.0, green: 0x48/255.0, blue: 0x4A/255.0, alpha: 1)
            : UIColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x1A/255.0, alpha: 1)
    })

    static let subtleFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.05)
    })

    static let inactiveIndicator = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x48/255.0, green: 0x48/255.0, blue: 0x4A/255.0, alpha: 1)
            : UIColor(red: 0xD0/255.0, green: 0xD0/255.0, blue: 0xD0/255.0, alpha: 1)
    })

}

// MARK: - Map Style

enum GeoMapStyle: String, CaseIterable {
    case mono
    case standard
    case satellite

    var displayName: String {
        switch self {
        case .mono:      return "MONO"
        case .standard:  return "COLOR"
        case .satellite: return "SATELLITE"
        }
    }
}

// MARK: - Memo Colors

enum MemoColor: Int, CaseIterable {
    case blue = 0, red, amber, green, purple, gray

    var accessibilityName: String {
        switch self {
        case .blue:   return String(localized: "Blue")
        case .red:    return String(localized: "Red")
        case .amber:  return String(localized: "Orange")
        case .green:  return String(localized: "Green")
        case .purple: return String(localized: "Purple")
        case .gray:   return String(localized: "Gray")
        }
    }

    var color: Color {
        switch self {
        case .blue:   return Brand.blue
        case .red:    return Color(hex: "E5484D")
        case .amber:  return Color(hex: "E5A000")
        case .green:  return Color(hex: "30A46C")
        case .purple: return Color(hex: "8E4EC6")
        case .gray:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0x70/255.0, green: 0x6F/255.0, blue: 0x78/255.0, alpha: 1)
                    : UIColor(red: 0x8B/255.0, green: 0x8D/255.0, blue: 0x98/255.0, alpha: 1)
            })
        }
    }
}

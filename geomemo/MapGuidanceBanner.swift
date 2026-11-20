import SwiftUI

// 地図の上部に出す、許可の不足・監視上限の案内バナー。
// 何を出すかは PermissionGuidance.swift の MapGuidance が決める（この View は表示だけ）。

extension MapGuidance {
    var iconName: String {
        switch self {
        case .permission(let notice):
            switch notice {
            case .notificationsDenied, .notificationsNotDetermined: return "bell.slash.fill"
            default: return "location.slash.fill"
            }
        case .monitoringLimit: return "exclamationmark.triangle.fill"
        }
    }

    var title: String {
        switch self {
        case .permission(let notice):
            switch notice {
            case .locationDenied: return String(localized: "Location is off")
            case .locationRestricted: return String(localized: "Location is restricted")
            case .locationNotDetermined: return String(localized: "Location isn't set up yet")
            case .locationWhenInUseOnly: return String(localized: "Alerts only work while the app is open")
            case .locationReducedAccuracy: return String(localized: "Precise Location is off")
            case .notificationsDenied: return String(localized: "Notifications are off")
            case .notificationsNotDetermined: return String(localized: "Notifications aren't set up yet")
            }
        case .monitoringLimit(.overLimit):
            return String(localized: "Too many places to watch")
        case .monitoringLimit:
            return String(localized: "Nearing the 20-place limit")
        }
    }

    var message: String {
        switch self {
        case .permission(let notice):
            switch notice {
            case .locationDenied:
                return String(localized: "GeoMemo can't tell when you reach a saved place. Turn on Location in Settings.")
            case .locationRestricted:
                return String(localized: "Location can't be changed in Settings on this device (for example, due to parental controls).")
            case .locationNotDetermined:
                return String(localized: "Allow location to see your position and get arrival alerts.")
            case .locationWhenInUseOnly:
                return String(localized: "Location is set to “While Using”, so alerts only arrive while the app is open. You can change this to be notified when it's closed.")
            case .locationReducedAccuracy:
                return String(localized: "Alerts for small areas may be late or missed. Turn on Precise Location in Settings.")
            case .notificationsDenied:
                return String(localized: "You won't see alerts even when you reach a place. Turn on Notifications in Settings.")
            case .notificationsNotDetermined:
                return String(localized: "Allow notifications to be told when you reach a place.")
            }
        case .monitoringLimit(.overLimit(_, let unmonitored)):
            return String(localized: "iOS can watch up to 20 places. \(unmonitored) won't send alerts. Complete or delete some memos.")
        case .monitoringLimit(.nearLimit(let used)):
            return String(localized: "\(used) of 20 places are being watched. iOS can't watch more than 20.")
        case .monitoringLimit(.ok):
            return ""
        }
    }

    /// ボタンの文言。ボタンが無い案内は nil。
    var actionTitle: String? {
        guard case .permission(let notice) = self, let action = notice.action else { return nil }
        switch action {
        case .openSettings: return String(localized: "Open Settings")
        case .requestAlways: return String(localized: "Change Location Access")
        case .requestLocation, .requestNotifications: return String(localized: "Allow")
        }
    }
}

struct MapGuidanceBanner: View {
    let guidance: MapGuidance
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: guidance.iconName)
                .font(.callout.weight(.semibold))
                .foregroundColor(Brand.warning)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(guidance.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Brand.primaryText)
                Text(guidance.message)
                    .font(.caption)
                    .foregroundColor(Brand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle = guidance.actionTitle {
                    Button(action: onAction) {
                        Text(actionTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Brand.blue)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mapGuidance.action")
                }
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Brand.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, -8)
            .padding(.top, -10)
            .accessibilityLabel(String(localized: "Dismiss"))
            .accessibilityIdentifier("mapGuidance.dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Brand.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        // バナーが出たとき（案内が変わったとき）に VoiceOver で読み上げる。
        .task(id: guidance) {
            AccessibilityNotification.Announcement("\(guidance.title). \(guidance.message)").post()
        }
    }
}

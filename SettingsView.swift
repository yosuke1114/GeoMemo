//
//  SettingsView.swift
//  geomemo
//
//  Created by 黒滝洋輔 on 2026/03/29.
//

import SwiftUI
import CoreLocation
import UserNotifications
// Phosphor icons loaded from local Assets.xcassets

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("notifyOnEntry") private var notifyOnEntry = true
    @AppStorage("notifyOnExit") private var notifyOnExit = true
    @AppStorage("defaultRadius") private var defaultRadius: Double = 100

    @State private var locationStatus: String = "確認中..."
    @State private var notificationStatus: String = "確認中..."
    @State private var showRadiusPicker = false

    private let brandBlue = Color(hex: "3D3BF3")
    private let brandBlack = Color(hex: "1A1A1A")

    var body: some View {
        List {
            // MARK: - NOTIFICATIONS
            Section {
                Toggle("通知", isOn: $notificationsEnabled)
                    .tint(brandBlue)
                Toggle("到着時に通知", isOn: $notifyOnEntry)
                    .tint(brandBlue)
                Toggle("離脱時に通知", isOn: $notifyOnExit)
                    .tint(brandBlue)
            } header: {
                Text("NOTIFICATIONS")
            }

            // MARK: - DEFAULTS
            Section {
                Button {
                    showRadiusPicker = true
                } label: {
                    HStack {
                        Text("デフォルト半径")
                            .foregroundColor(brandBlack)
                        Spacer()
                        Text(radiusLabel)
                            .foregroundColor(.gray)
                        Image("ph-caret-right-bold")
                            .resizable()
                            .frame(width: 12, height: 12)
                            .foregroundColor(.gray)
                    }
                }
            } header: {
                Text("DEFAULTS")
            }

            // MARK: - PERMISSIONS
            Section {
                Button {
                    openSettings()
                } label: {
                    HStack {
                        Text("位置情報")
                            .foregroundColor(brandBlack)
                        Spacer()
                        Text(locationStatus)
                            .foregroundColor(.gray)
                        Image("ph-caret-right-bold")
                            .resizable()
                            .frame(width: 12, height: 12)
                            .foregroundColor(.gray)
                    }
                }

                Button {
                    openSettings()
                } label: {
                    HStack {
                        Text("通知")
                            .foregroundColor(brandBlack)
                        Spacer()
                        Text(notificationStatus)
                            .foregroundColor(.gray)
                        Image("ph-caret-right-bold")
                            .resizable()
                            .frame(width: 12, height: 12)
                            .foregroundColor(.gray)
                    }
                }
            } header: {
                Text("PERMISSIONS")
            }

            // MARK: - ABOUT
            Section {
                HStack {
                    Text("バージョン")
                        .foregroundColor(brandBlack)
                    Spacer()
                    Text(appVersion)
                        .foregroundColor(.gray)
                }

                NavigationLink {
                    LicenseView()
                } label: {
                    Text("ライセンス")
                        .foregroundColor(brandBlack)
                }
            } header: {
                Text("ABOUT")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(hex: "F9F9F9"))
        .navigationTitle("SETTINGS")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image("ph-caret-left-bold")
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text("戻る")
                            .font(.system(size: 16))
                    }
                    .foregroundColor(brandBlue)
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showRadiusPicker) {
            RadiusPickerSheet(selectedRadius: $defaultRadius)
                .presentationDetents([.height(320)])
        }
        .task {
            await updatePermissionStatuses()
        }
    }

    // MARK: - Computed Properties

    private var radiusLabel: String {
        switch defaultRadius {
        case 50: return "50M"
        case 100: return "100M"
        case 500: return "500M"
        case 1000: return "1KM"
        default: return "\(Int(defaultRadius))M"
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    // MARK: - Actions

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func updatePermissionStatuses() async {
        // Location
        let locStatus = CLLocationManager().authorizationStatus
        let locText: String
        switch locStatus {
        case .authorizedAlways: locText = "常に許可"
        case .authorizedWhenInUse: locText = "使用中のみ"
        case .denied: locText = "拒否"
        case .restricted: locText = "制限あり"
        case .notDetermined: locText = "未設定"
        @unknown default: locText = "不明"
        }
        locationStatus = locText

        // Notification
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let notifText: String
        switch settings.authorizationStatus {
        case .authorized: notifText = "許可"
        case .denied: notifText = "拒否"
        case .provisional: notifText = "仮許可"
        case .notDetermined: notifText = "未設定"
        case .ephemeral: notifText = "一時的"
        @unknown default: notifText = "不明"
        }
        notificationStatus = notifText
    }
}

// MARK: - Radius Picker Sheet

private struct RadiusPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedRadius: Double

    private let brandBlue = Color(hex: "3D3BF3")
    private let brandBlack = Color(hex: "1A1A1A")

    private let options: [(label: String, value: Double)] = [
        ("50M", 50),
        ("100M", 100),
        ("500M", 500),
        ("1KM", 1000),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(options, id: \.value) { option in
                    Button {
                        selectedRadius = option.value
                        dismiss()
                    } label: {
                        HStack {
                            Text(option.label)
                                .foregroundColor(brandBlack)
                            Spacer()
                            if selectedRadius == option.value {
                                Image("ph-check-bold")
                                    .resizable()
                                    .frame(width: 14, height: 14)
                                    .foregroundColor(brandBlue)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(hex: "F9F9F9"))
            .navigationTitle("デフォルト半径")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完了") {
                        dismiss()
                    }
                    .foregroundColor(brandBlue)
                }
            }
        }
    }
}

// MARK: - License View

struct LicenseView: View {
    private let brandBlack = Color(hex: "1A1A1A")

    var body: some View {
        List {
            Section {
                Text("このアプリはオープンソースライブラリを使用していません。")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(hex: "F9F9F9"))
        .navigationTitle("ライセンス")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Color Extension

private extension Color {
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hexSanitized.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 255, 255, 255)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SettingsView()
    }
}

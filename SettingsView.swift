//
//  SettingsView.swift
//  geomemo
//
//  Created by 黒滝洋輔 on 2026/03/29.
//

import SwiftUI
import SwiftData
import CoreLocation
import UserNotifications
import UniformTypeIdentifiers
// Phosphor icons loaded from local Assets.xcassets

// MARK: - Exporter helper

enum GeoMemoExporter {
    static func makeTempFile(memos: [GeoMemo]) throws -> URL {
        let backupMemos = memos.map { BackupMemo(from: $0) }
        let file = GeoMemoBackupFile(memos: backupMemos)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename())
        try data.write(to: url)
        return url
    }

    static func filename(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "geomemo_backup_\(formatter.string(from: date)).json"
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var memos: [GeoMemo]

    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.system.rawValue
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("notifyOnEntry") private var notifyOnEntry = true
    @AppStorage("notifyOnExit") private var notifyOnExit = true
    @AppStorage("defaultRadius") private var defaultRadius: Double = 100
    @AppStorage("mapStyle") private var mapStyleRaw: String = GeoMapStyle.mono.rawValue

    @State private var locationStatus: String = String(localized: "Checking...")
    @State private var notificationStatus: String = String(localized: "Checking...")
    @State private var showRadiusPicker = false

    // Export / Import
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var importAlertMessage: String?
    @State private var showImportAlert = false
    @State private var exportError: String?
    @State private var showExportError = false

    private var iCloudEnabled: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    var body: some View {
        List {
            // MARK: - NOTIFICATIONS
            Section {
                Toggle("Notifications", isOn: $notificationsEnabled)
                    .tint(Brand.blue)
                Toggle("Notify on arrival", isOn: $notifyOnEntry)
                    .tint(Brand.blue)
                Toggle("Notify on departure", isOn: $notifyOnExit)
                    .tint(Brand.blue)
            } header: {
                Text("NOTIFICATIONS")
            }

            // MARK: - APPEARANCE
            Section {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Button {
                        HapticManager.selection()
                        appearanceMode = mode.rawValue
                    } label: {
                        HStack {
                            Text(mode.displayName)
                                .foregroundColor(Brand.primaryText)
                            Spacer()
                            if appearanceMode == mode.rawValue {
                                Image("ph-check-bold")
                                    .resizable()
                                    .frame(width: 14, height: 14)
                                    .foregroundColor(Brand.blue)
                            }
                        }
                    }
                }
            } header: {
                Text("APPEARANCE")
            }

            // MARK: - MAP STYLE
            Section {
                ForEach(GeoMapStyle.allCases, id: \.self) { style in
                    Button {
                        HapticManager.selection()
                        mapStyleRaw = style.rawValue
                    } label: {
                        HStack {
                            Text(style.displayName)
                                .foregroundColor(Brand.primaryText)
                            Spacer()
                            if mapStyleRaw == style.rawValue {
                                Image("ph-check-bold")
                                    .resizable()
                                    .frame(width: 14, height: 14)
                                    .foregroundColor(Brand.blue)
                            }
                        }
                    }
                }
            } header: {
                Text("MAP STYLE")
            }

            // MARK: - DEFAULTS
            Section {
                Button {
                    showRadiusPicker = true
                } label: {
                    HStack {
                        Text("Default Radius")
                            .foregroundColor(Brand.primaryText)
                        Spacer()
                        Text(radiusLabel)
                            .foregroundColor(Brand.secondaryText)
                        Image("ph-caret-right-bold")
                            .resizable()
                            .frame(width: 12, height: 12)
                            .foregroundColor(Brand.secondaryText)
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
                        Text("Location")
                            .foregroundColor(Brand.primaryText)
                        Spacer()
                        Text(locationStatus)
                            .foregroundColor(Brand.secondaryText)
                        Image("ph-caret-right-bold")
                            .resizable()
                            .frame(width: 12, height: 12)
                            .foregroundColor(Brand.secondaryText)
                    }
                }

                Button {
                    openSettings()
                } label: {
                    HStack {
                        Text("Notifications")
                            .foregroundColor(Brand.primaryText)
                        Spacer()
                        Text(notificationStatus)
                            .foregroundColor(Brand.secondaryText)
                        Image("ph-caret-right-bold")
                            .resizable()
                            .frame(width: 12, height: 12)
                            .foregroundColor(Brand.secondaryText)
                    }
                }
            } header: {
                Text("PERMISSIONS")
            }

            // MARK: - DATA
            Section {
                // Export
                if let url = exportURL {
                    ShareLink(item: url) {
                        HStack {
                            Text("Export backup")
                                .foregroundColor(Brand.primaryText)
                            Spacer()
                            Text("\(memos.count) memos")
                                .foregroundColor(Brand.secondaryText)
                            Image("ph-caret-right-bold")
                                .resizable()
                                .frame(width: 12, height: 12)
                                .foregroundColor(Brand.secondaryText)
                        }
                    }
                } else {
                    Button {
                        do {
                            exportURL = try GeoMemoExporter.makeTempFile(memos: memos)
                        } catch {
                            exportError = error.localizedDescription
                            showExportError = true
                        }
                    } label: {
                        HStack {
                            Text("Export backup")
                                .foregroundColor(Brand.primaryText)
                            Spacer()
                            Text("\(memos.count) memos")
                                .foregroundColor(Brand.secondaryText)
                            Image("ph-caret-right-bold")
                                .resizable()
                                .frame(width: 12, height: 12)
                                .foregroundColor(Brand.secondaryText)
                        }
                    }
                }

                // Import
                Button {
                    showImporter = true
                } label: {
                    HStack {
                        Text("Import backup")
                            .foregroundColor(Brand.primaryText)
                        Spacer()
                        Image("ph-caret-right-bold")
                            .resizable()
                            .frame(width: 12, height: 12)
                            .foregroundColor(Brand.secondaryText)
                    }
                }
            } header: {
                Text("DATA")
            } footer: {
                if iCloudEnabled {
                    Text("iCloud sync is ON. Your memos are automatically restored when signing in on a new device. If iCloud storage is full, sync may pause — check in iOS Settings > Apple ID > iCloud.")
                } else {
                    Text("iCloud sync is OFF. Export a backup and save it to Files before switching devices, then import it on your new device.")
                        .foregroundColor(.orange)
                }
            }

            // MARK: - ABOUT
            Section {
                HStack {
                    Text("Version")
                        .foregroundColor(Brand.primaryText)
                    Spacer()
                    Text(appVersion)
                        .foregroundColor(Brand.secondaryText)
                }

                HStack {
                    Text("iCloud Sync")
                        .foregroundColor(Brand.primaryText)
                    Spacer()
                    Text(FileManager.default.ubiquityIdentityToken != nil ? String(localized: "Enabled") : String(localized: "Disabled"))
                        .foregroundColor(Brand.secondaryText)
                }

                NavigationLink {
                    LicenseView()
                } label: {
                    Text("Licenses")
                        .foregroundColor(Brand.primaryText)
                }
            } header: {
                Text("ABOUT")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.tertiaryBackground)
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
                        Text("Back")
                            .font(.system(size: 16))
                    }
                    .foregroundColor(Brand.blue)
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showRadiusPicker) {
            RadiusPickerSheet(selectedRadius: $defaultRadius)
                .presentationDetents([.height(320)])
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .failure(let error):
                importAlertMessage = error.localizedDescription
                showImportAlert = true
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    let data = try Data(contentsOf: url)
                    let importResult = try GeoMemoImporter.importData(from: data, into: modelContext)
                    importAlertMessage = String(
                        format: String(localized: "Import complete: %d added, %d skipped (already existed)."),
                        importResult.added,
                        importResult.skipped
                    )
                    showImportAlert = true
                } catch {
                    importAlertMessage = error.localizedDescription
                    showImportAlert = true
                }
            }
        }
        .alert("Import", isPresented: $showImportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importAlertMessage ?? "")
        }
        .alert("Export failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
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
        case .authorizedAlways: locText = String(localized: "Always")
        case .authorizedWhenInUse: locText = String(localized: "While Using")
        case .denied: locText = String(localized: "Denied")
        case .restricted: locText = String(localized: "Restricted")
        case .notDetermined: locText = String(localized: "Not Set")
        @unknown default: locText = String(localized: "Unknown")
        }
        locationStatus = locText

        // Notification
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let notifText: String
        switch settings.authorizationStatus {
        case .authorized: notifText = String(localized: "Authorized")
        case .denied: notifText = String(localized: "Denied")
        case .provisional: notifText = String(localized: "Provisional")
        case .notDetermined: notifText = String(localized: "Not Set")
        case .ephemeral: notifText = String(localized: "Ephemeral")
        @unknown default: notifText = String(localized: "Unknown")
        }
        notificationStatus = notifText
    }
}

// MARK: - Radius Picker Sheet

private struct RadiusPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedRadius: Double

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
                                .foregroundColor(Brand.primaryText)
                            Spacer()
                            if selectedRadius == option.value {
                                Image("ph-check-bold")
                                    .resizable()
                                    .frame(width: 14, height: 14)
                                    .foregroundColor(Brand.blue)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.tertiaryBackground)
            .navigationTitle("Default Radius")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(Brand.blue)
                }
            }
        }
    }
}

// MARK: - License View

struct LicenseView: View {
    var body: some View {
        List {
            Section {
                Text("This app does not use any open source libraries.")
                    .font(.system(size: 14))
                    .foregroundColor(Brand.secondaryText)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.tertiaryBackground)
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Brand colors and Color(hex:) are defined in Theme.swift

// MARK: - Preview

#Preview {
    NavigationStack {
        SettingsView()
    }
}

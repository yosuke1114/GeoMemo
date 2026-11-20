import SwiftUI
import SwiftData
import UIKit
import Combine

/// 設定 → PERMISSIONS →「通知のチェック」。通知が届かない原因になりうる設定を 1 画面に並べる。
/// 判定と文言は NotificationDiagnostics.swift（純粋なロジック）。この View は表示と、システムの値の読み取りだけ。
struct NotificationCheckView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query private var memos: [GeoMemo]
    @Query private var sharedMemos: [SharedMemo]
    @ObservedObject private var locationManager = LocationManager.shared
    @ObservedObject private var notificationManager = NotificationManager.shared
    @AppStorage("notificationsEnabled") private var inAppNotificationsEnabled = true

    @State private var snapshot = SystemSnapshot.read()
    @State private var performer = PermissionActionPerformer()
    @State private var isSendingTest = false
    @State private var testResult: TestNotificationResult?

    /// OS から読む値のうち、@Published でないもの。
    struct SystemSnapshot: Equatable {
        var backgroundRefresh: BackgroundRefreshAccess
        var isLowPowerMode: Bool
        var monitoredRegions: Int
        var isMonitoringAvailable: Bool
        var lastRegionEventAt: Date?
        var lastNotificationAt: Date?

        @MainActor
        static func read() -> SystemSnapshot {
            let refresh: BackgroundRefreshAccess
            switch UIApplication.shared.backgroundRefreshStatus {
            case .available: refresh = .available
            case .denied: refresh = .denied
            default: refresh = .restricted
            }
            return SystemSnapshot(
                backgroundRefresh: refresh,
                isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                monitoredRegions: LocationManager.shared.monitoredRegionCount,
                isMonitoringAvailable: LocationManager.isGeofencingAvailable,
                lastRegionEventAt: DiagnosticsLog.shared.lastRegionEventAt,
                lastNotificationAt: DiagnosticsLog.shared.lastNotificationAt)
        }
    }

    private var input: DiagnosticInput {
        DiagnosticInput.current(
            locationManager: locationManager, notificationManager: notificationManager,
            inAppNotificationsEnabled: inAppNotificationsEnabled, snapshot: snapshot,
            memos: memos, sharedMemos: sharedMemos)
    }

    private var canSendTest: Bool { NotificationAccess(notificationManager.authorizationStatus) == .allowed }

    var body: some View {
        let currentInput = input
        let currentItems = NotificationDiagnostics.evaluate(currentInput)
        let count = NotificationDiagnostics.issueCount(currentItems)
        List {
            Section {
                Label {
                    Text(DiagnosticText.summary(issueCount: count))
                        .font(.body.weight(.semibold))
                        .foregroundColor(Brand.primaryText)
                } icon: {
                    Image(systemName: count == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(count == 0 ? Brand.blue : Brand.warning)
                        .accessibilityHidden(true)
                }
                .accessibilityIdentifier("notificationCheck.summary")
            }

            Section {
                ForEach(currentItems) { item in
                    row(item, input: currentInput)
                }
            }

            Section {
                LabeledContent {
                    Text(timeText(snapshot.lastRegionEventAt)).foregroundColor(Brand.secondaryText)
                } label: {
                    Text("Last time a place was detected")
                }
                LabeledContent {
                    Text(timeText(snapshot.lastNotificationAt)).foregroundColor(Brand.secondaryText)
                } label: {
                    Text("Last alert sent")
                }
            } footer: {
                Text("Only the time is recorded, not the place. It stays on this device.")
            }

            Section {
                Button {
                    sendTest()
                } label: {
                    HStack {
                        Text("Send a Test Alert")
                        if isSendingTest {
                            Spacer()
                            ProgressView()
                        }
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
                .disabled(!canSendTest || isSendingTest)
                .accessibilityIdentifier("notificationCheck.sendTest")

                if let testResult {
                    Text(DiagnosticText.testResultMessage(testResult))
                        .font(.footnote)
                        .foregroundColor(Brand.secondaryText)
                        .accessibilityIdentifier("notificationCheck.testResult")
                }
            } footer: {
                if canSendTest {
                    Text("A test alert will arrive in 5 seconds. Lock the screen or go to the Home Screen to see how it appears.")
                } else if notificationManager.authorizationStatus != nil {
                    Text("Allow notifications first.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.background)
        .navigationTitle("Notification Check")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            notificationManager.checkAuthorizationStatus()
            reload()
            announceSummary(count)
        }
        .onChange(of: scenePhase) { _, phase in
            performer.scenePhaseChanged(phase)
            if phase == .active {
                notificationManager.checkAuthorizationStatus()
                reload()
            }
        }
        .onChange(of: locationManager.authorizationStatus) { _, _ in reload() }
        .onChange(of: locationManager.isPreciseLocation) { _, _ in reload() }
        .onChange(of: notificationManager.authorizationStatus) { _, _ in reload() }
        // 低電力モードの変更の通知は、どのスレッドから届くか分からない。MainActor のクロージャを
        // 別スレッドで呼ぶと Swift 6 の実行時の隔離チェックで落ちるので、main に寄せてから受ける。
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)) { _ in reload() }
        .onChange(of: count) { _, new in announceSummary(new) }
        .onDisappear { performer.cancel() }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ item: DiagnosticItem, input: DiagnosticInput) -> some View {
        let value = DiagnosticText.value(item, input: input)
        let headline = DiagnosticText.headline(item)
        let message = DiagnosticText.message(item)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent {
                    Text(value)
                        .foregroundColor(Brand.secondaryText)
                        .multilineTextAlignment(.trailing)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(item.severity))
                            .foregroundColor(color(item.severity))
                            .accessibilityHidden(true)
                        Text(DiagnosticText.title(item.id))
                            .foregroundColor(Brand.primaryText)
                    }
                }
                if let headline {
                    Text(headline)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Brand.primaryText)
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(Brand.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText(item, value: value, headline: headline, message: message))

            if let action = item.action {
                Button {
                    perform(action)
                } label: {
                    Text(DiagnosticText.actionTitle(action))
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Brand.blue)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("notificationCheck.action.\(item.id.rawValue)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("notificationCheck.row.\(item.id.rawValue)")
    }

    private func accessibilityText(_ item: DiagnosticItem, value: String, headline: String?, message: String?) -> String {
        var parts = [DiagnosticText.title(item.id), DiagnosticText.severityLabel(item.severity)]
        if value != DiagnosticText.severityLabel(item.severity) { parts.append(value) }
        if let headline { parts.append(headline) }
        if let message { parts.append(message) }
        return parts.joined(separator: ", ")
    }

    private func icon(_ severity: DiagnosticSeverity) -> String {
        switch severity {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        }
    }

    private func color(_ severity: DiagnosticSeverity) -> Color {
        switch severity {
        case .ok, .info: return Brand.secondaryText
        case .warning, .problem: return Brand.warning
        }
    }

    private func timeText(_ date: Date?) -> String {
        date.map { dayAndTimeText($0) } ?? String(localized: "Not yet")
    }

    // MARK: - Actions

    private func perform(_ action: DiagnosticAction) {
        switch action {
        case .permission(let a):
            performer.perform(a)
        case .openNotificationSettings:
            HapticManager.impact(.light)
            PermissionActionPerformer.openNotificationSettings()
        case .enableInAppNotifications:
            HapticManager.impact(.light)
            inAppNotificationsEnabled = true
        case .reRegisterGeofences:
            HapticManager.impact(.light)
            GeofenceRegistrar.reRegisterAll(memos: memos, sharedMemos: sharedMemos)
            reload()
        }
    }

    private func sendTest() {
        guard !isSendingTest else { return }
        HapticManager.impact(.light)
        isSendingTest = true
        testResult = nil
        Task {
            let result = await notificationManager.sendTestNotification()
            testResult = result
            isSendingTest = false
            AccessibilityNotification.Announcement(DiagnosticText.testResultMessage(result)).post()
        }
    }

    private func reload() {
        snapshot = SystemSnapshot.read()
    }

    private func announceSummary(_ count: Int) {
        AccessibilityNotification.Announcement(DiagnosticText.summary(issueCount: count)).post()
    }
}

extension DiagnosticInput {
    /// 画面（通知のチェック・設定の入口）が使う、現在の状態。
    @MainActor
    static func current(
        locationManager: LocationManager,
        notificationManager: NotificationManager,
        inAppNotificationsEnabled: Bool,
        snapshot: NotificationCheckView.SystemSnapshot,
        memos: [GeoMemo],
        sharedMemos: [SharedMemo]
    ) -> DiagnosticInput {
        DiagnosticInput(
            permissions: PermissionSnapshot(
                location: LocationAccess(locationManager.authorizationStatus),
                isPreciseLocation: locationManager.isPreciseLocation,
                notification: NotificationAccess(notificationManager.authorizationStatus)),
            presentation: notificationManager.presentation,
            inAppNotificationsEnabled: inAppNotificationsEnabled,
            backgroundRefresh: snapshot.backgroundRefresh,
            isLowPowerMode: snapshot.isLowPowerMode,
            requiredRegions: GeofenceRegistrar.requiredRegionCount(memos: memos, sharedMemos: sharedMemos),
            monitoredRegions: snapshot.monitoredRegions,
            isMonitoringAvailable: snapshot.isMonitoringAvailable)
    }
}

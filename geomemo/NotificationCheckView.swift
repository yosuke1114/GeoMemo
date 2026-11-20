import SwiftUI
import SwiftData
import UIKit
import Combine
import CoreLocation

/// 設定 → PERMISSIONS →「通知のチェック」。通知が届かない原因になりうる設定を 1 画面に並べる。
/// 判定と文言は NotificationDiagnostics.swift（純粋なロジック）。この View は表示と、システムの値の読み取りだけ。
struct NotificationCheckView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query private var memos: [GeoMemo]
    @Query private var sharedMemos: [SharedMemo]
    // LocationManager 全体は監視しない（位置・方位の更新のたびに画面が描き直されるため）。
    // 必要な値だけ onReceive で @State に写す。
    private let locationManager = LocationManager.shared
    @ObservedObject private var notificationManager = NotificationManager.shared
    @AppStorage("notificationsEnabled") private var inAppNotificationsEnabled = true

    @State private var locationAuthorization: CLAuthorizationStatus = LocationManager.shared.authorizationStatus
    @State private var isPreciseLocation = LocationManager.shared.isPreciseLocation
    @State private var snapshot: SystemSnapshot?
    @State private var input: DiagnosticInput?
    @State private var items: [DiagnosticItem] = []
    @State private var issueCount = 0
    @State private var performer: PermissionActionPerformer?
    @State private var announceArmed = false
    @State private var isSendingTest = false
    @State private var testResult: TestNotificationResult?

    /// OS から読む値のうち、@Published でないもの。
    struct SystemSnapshot: Equatable {
        var backgroundRefresh: BackgroundRefreshAccess
        var isLowPowerMode: Bool
        var monitoredRegions: Int
        var monitoredIdentifiers: Set<String>
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
                monitoredIdentifiers: LocationManager.shared.monitoredRegionIdentifiers,
                isMonitoringAvailable: LocationManager.isGeofencingAvailable,
                lastRegionEventAt: DiagnosticsLog.shared.lastRegionEventAt,
                lastNotificationAt: DiagnosticsLog.shared.lastNotificationAt)
        }
    }

    private var canSendTest: Bool { NotificationAccess(notificationManager.authorizationStatus) == .allowed }

    /// 材料が変わったときだけ、判定をやり直す（body の評価のたびには計算しない）。
    private func recompute() {
        let snap = snapshot ?? SystemSnapshot.read()
        snapshot = snap
        let new = DiagnosticInput.current(
            locationAuthorization: locationAuthorization, isPreciseLocation: isPreciseLocation,
            notificationManager: notificationManager,
            inAppNotificationsEnabled: inAppNotificationsEnabled, snapshot: snap,
            memos: memos, sharedMemos: sharedMemos)
        input = new
        items = NotificationDiagnostics.evaluate(new)
        issueCount = NotificationDiagnostics.issueCount(items)
    }

    var body: some View {
        let count = issueCount
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
                if let currentInput = input {
                    ForEach(items) { item in
                        row(item, input: currentInput)
                    }
                }
            }

            Section {
                LabeledContent {
                    Text(timeText(snapshot?.lastRegionEventAt)).foregroundColor(Brand.secondaryText)
                } label: {
                    Text("Last time a place was detected")
                }
                LabeledContent {
                    Text(timeText(snapshot?.lastNotificationAt)).foregroundColor(Brand.secondaryText)
                } label: {
                    Text("Last alert sent")
                }
            } footer: {
                Text("Only the time is recorded, not the place. GeoMemo never sends it anywhere.")
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
            if performer == nil { performer = PermissionActionPerformer() }
            notificationManager.checkAuthorizationStatus()
            recompute()
            // 開いた直後のまとめは読み上げない（画面の読み上げと重なる）。少し待ってから、変化だけ読む。
            try? await Task.sleep(for: .seconds(1))
            announceArmed = true
        }
        .onChange(of: scenePhase) { _, phase in
            performer?.scenePhaseChanged(phase)
            if phase == .active {
                notificationManager.checkAuthorizationStatus()
                reload()
            }
        }
        // `receive(on:)` で main に寄せてから受ける（どのスレッドから来ても MainActor のクロージャを main で呼ぶ）。
        .onReceive(locationManager.$authorizationStatus.removeDuplicates().receive(on: DispatchQueue.main)) { status in
            locationAuthorization = status
            if snapshot != nil { reload() }
        }
        .onReceive(locationManager.$isPreciseLocation.removeDuplicates().receive(on: DispatchQueue.main)) { precise in
            isPreciseLocation = precise
            if snapshot != nil { reload() }
        }
        .onChange(of: notificationManager.authorizationStatus) { _, _ in reload() }
        .onChange(of: notificationManager.presentation) { _, _ in reload() }
        .onChange(of: inAppNotificationsEnabled) { _, _ in reload() }
        .onChange(of: memos.count) { _, _ in reload() }
        .onChange(of: sharedMemos.count) { _, _ in reload() }
        // 低電力モードの通知は、どのスレッドから届くか分からない。MainActor のクロージャを
        // 別スレッドで呼ぶと Swift 6 の実行時の隔離チェックで落ちるので、main に寄せてから受ける。
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)) { _ in reload() }
        // まとめの読み上げは、件数が変わったとき（登録し直し・設定から戻った後）だけ。開いた直後は読まない。
        .onChange(of: count) { old, new in
            if announceArmed && old != new { announceSummary(new) }
        }
        .onDisappear { performer?.cancel() }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ item: DiagnosticItem, input: DiagnosticInput) -> some View {
        let value = DiagnosticText.value(item, input: input)
        let headline = DiagnosticText.headline(item)
        let message = DiagnosticText.message(item, input: input)
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
            performer?.perform(a)
        case .openNotificationSettings:
            HapticManager.impact(.light)
            PermissionActionPerformer.openNotificationSettings()
        case .enableInAppNotifications:
            HapticManager.impact(.light)
            inAppNotificationsEnabled = true
        case .reRegisterGeofences:
            HapticManager.impact(.light)
            GeofenceReconciler.reconcile(memos: memos, sharedMemos: sharedMemos)
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
        recompute()
    }

    private func announceSummary(_ count: Int) {
        AccessibilityNotification.Announcement(DiagnosticText.summary(issueCount: count)).post()
    }
}

extension DiagnosticInput {
    /// 画面（通知のチェック・設定の入口）が使う、現在の状態。
    @MainActor
    static func current(
        locationAuthorization: CLAuthorizationStatus,
        isPreciseLocation: Bool,
        notificationManager: NotificationManager,
        inAppNotificationsEnabled: Bool,
        snapshot: NotificationCheckView.SystemSnapshot,
        memos: [GeoMemo],
        sharedMemos: [SharedMemo]
    ) -> DiagnosticInput {
        let receivedUnmonitored = sharedMemos
            .filter { !$0.isMyRequest && $0.status == .active }
            .filter { !snapshot.monitoredIdentifiers.contains($0.geofenceIdentifier) }
            .count
        return DiagnosticInput(
            permissions: PermissionSnapshot(
                location: LocationAccess(locationAuthorization),
                isPreciseLocation: isPreciseLocation,
                notification: NotificationAccess(notificationManager.authorizationStatus)),
            presentation: notificationManager.presentation,
            inAppNotificationsEnabled: inAppNotificationsEnabled,
            backgroundRefresh: snapshot.backgroundRefresh,
            isLowPowerMode: snapshot.isLowPowerMode,
            requiredRegions: GeofenceRegistrar.requiredRegionCount(memos: memos, sharedMemos: sharedMemos),
            monitoredRegions: snapshot.monitoredRegions,
            isMonitoringAvailable: snapshot.isMonitoringAvailable,
            receivedUnmonitored: receivedUnmonitored)
    }
}

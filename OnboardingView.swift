//
//  OnboardingView.swift
//  geomemo
//
//  Created by 黒滝洋輔 on 2026/03/29.
//

import SwiftUI
// Phosphor icons loaded from local Assets.xcassets

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var locationManager = LocationManager.shared
    @State private var step: OnboardingStep = .welcome
    /// システムの許可ダイアログの結果を待っている間 true（二重タップと、ダイアログに重なる画面遷移を防ぐ）。
    @State private var awaitingSystemDialog = false
    /// 「常に」のダイアログが出たか（scenePhase で判定）を見張る。
    @State private var dialogProbe = SystemDialogProbe()
    @AccessibilityFocusState private var titleFocused: Bool

    private var pageCount: Int { OnboardingStep.allCases.count }

    var body: some View {
        VStack(spacing: 0) {
            // ページはボタンでだけ進める（スワイプで許可の説明を飛ばせないようにする）。
            // 大きな文字サイズでも切れないよう ScrollView で包む（収まるときはスクロールしない）。
            GeometryReader { geo in
                ScrollView {
                    ZStack {
                        switch step {
                        case .welcome: welcomeContent
                        case .whenInUse: whenInUseContent
                        case .always: alwaysContent
                        case .notifications: notificationContent
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .id(step)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Page indicator
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s == step ? Brand.blue : Brand.inactiveIndicator)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .padding(.bottom, 32)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(step.rawValue + 1) of \(pageCount)")

            // Action area
            VStack(spacing: 8) {
                primaryButton(title: primaryTitle, action: handlePrimaryAction)
                    .disabled(awaitingSystemDialog)
                    .accessibilityIdentifier("onboarding.primary")
                if hasSecondaryAction {
                    Button(action: handleSecondaryAction) {
                        Text("Not Now")
                            .font(.callout)
                            .foregroundColor(Brand.secondaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(awaitingSystemDialog)
                    .accessibilityIdentifier("onboarding.secondary")
                } else {
                    Color.clear.frame(height: 44)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Brand.background)
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeInOut(duration: 0.25), value: step)
        // ページが変わったら、VoiceOver のフォーカスを題へ移す。
        .onChange(of: step) { _, _ in
            titleFocused = true
        }
        .onDisappear { dialogProbe.cancel() }
        // 使用中の許可ダイアログの結果（未決定 → 決定）で次へ進む。
        .onChange(of: locationManager.authorizationStatus) { _, newStatus in
            guard awaitingSystemDialog, step == .whenInUse, newStatus != .notDetermined else { return }
            finishAwaiting()
            advance()
        }
        // 「常に許可」のダイアログは、使用中のままを選ぶと状態が変わらないことがある。
        // ダイアログが閉じて画面が active に戻ったら進む（SystemDialogProbe が判定）。
        .onChange(of: scenePhase) { _, phase in
            guard step == .always else { return }
            dialogProbe.scenePhaseChanged(phase)
        }
    }

    /// システムのボタンに似せない。どの画面も「続ける」に統一する。
    private var primaryTitle: String { String(localized: "Continue") }

    private var hasSecondaryAction: Bool { step == .always || step == .notifications }

    // MARK: - Step 1: Welcome

    private var welcomeContent: some View {
        VStack(spacing: 0) {
            Spacer()

            GeoMemoIconView(size: 100)
                .padding(.bottom, 16)

            Text("GEOMEMO")
                .font(.largeTitle.weight(.bold))
                .foregroundColor(Brand.primaryText)
                .padding(.bottom, 8)

            Text("Leave memos at places")
                .font(.callout)
                .foregroundColor(Brand.secondaryText)

            Spacer()
        }
    }

    // MARK: - Step 2: While Using

    private var whenInUseContent: some View {
        permissionPage(
            image: "ph-navigation-arrow-fill",
            title: Text("Allow Location"),
            message: Text("While you use the app, GeoMemo shows where you are on the map and lets you pin memos nearby."),
            footnote: Text("You can choose on the next screen. You can change it later in Settings.")
        )
    }

    // MARK: - Step 3: Always (理由つき・あとでも可)

    private var alwaysContent: some View {
        permissionPage(
            image: "ph-navigation-arrow-fill",
            title: Text("Notify Even When Closed"),
            message: Text("To tell you when you reach a saved place while the app is closed, GeoMemo needs “Always” location access."),
            footnote: Text("You can choose on the next screen. You can change it later in Settings.")
        )
    }

    // MARK: - Step 4: Notifications

    private var notificationContent: some View {
        permissionPage(
            image: "ph-bell-fill",
            title: Text("Allow Notifications"),
            message: Text("Get notified when you enter\nor leave a saved location"),
            footnote: nil
        )
    }

    private func permissionPage(image: String, title: Text, message: Text, footnote: Text?) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("GeoMemo")
                    .font(.title3.weight(.bold))
                    .foregroundColor(Brand.primaryText)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer()

            Image(image)
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundColor(Brand.blue)
                .padding(.bottom, 24)

            title
                .font(.title2.weight(.bold))
                .foregroundColor(Brand.primaryText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)

            message
                .font(.subheadline)
                .foregroundColor(Brand.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let footnote {
                footnote
                    .font(.footnote)
                    .foregroundColor(Brand.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
            }

            Spacer()
        }
    }

    // MARK: - Components

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundColor(Brand.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Brand.blue)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    /// システムの許可ダイアログは、各ページの説明を読んでボタンを押したときにだけ出す。
    private func handlePrimaryAction() {
        HapticManager.impact(.light)
        switch step {
        case .welcome:
            advance()
        case .whenInUse:
            if LocationAccess(locationManager.authorizationStatus) == .notDetermined {
                beginAwaiting()
                locationManager.requestWhenInUseAuthorization()
            } else {
                advance() // 再インストールなどで既に決定済み。ダイアログは出ない。
            }
        case .always:
            beginAwaiting()
            let requested = locationManager.requestAlwaysAuthorization()
            // ダイアログが出た → 閉じて active に戻ったら進む。出なかった（既に尋ね済みなど）→ 止まらずに進む。
            // どちらでも 1 度だけ進む。
            dialogProbe.begin(requested: requested) { _ in
                finishAwaiting()
                advance()
            }
        case .notifications:
            beginAwaiting()
            Task {
                _ = await NotificationManager.shared.requestAuthorization()
                finishAwaiting()
                complete()
            }
        }
    }

    private func handleSecondaryAction() {
        HapticManager.impact(.light)
        switch step {
        case .notifications: complete()
        default: advance()
        }
    }

    private func beginAwaiting() {
        awaitingSystemDialog = true
    }

    private func finishAwaiting() {
        awaitingSystemDialog = false
        dialogProbe.cancel()
    }

    private func advance() {
        let location = LocationAccess(locationManager.authorizationStatus)
        if let next = OnboardingStep.next(after: step, location: location) {
            step = next
        } else {
            complete()
        }
    }

    private func complete() {
        hasCompletedOnboarding = true
    }
}

// Brand colors and Color(hex:) are defined in Theme.swift

// MARK: - Preview

#Preview {
    OnboardingView()
}

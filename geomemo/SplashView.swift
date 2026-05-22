import SwiftUI
import SwiftData
import CoreLocation
import UserNotifications

struct SplashView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showSplash = true

    private var isUITesting: Bool {
        CommandLine.arguments.contains("-UITesting")
    }

    /// UIテスト・ユニットテスト問わず「テスト実行中」かを検出
    private var isAnyTesting: Bool {
        isUITesting
            || ProcessInfo.processInfo.arguments.first?.contains("XCTestDevices") == true
    }

    var body: some View {
        ZStack {
            if showSplash && !isUITesting {
                SplashContent(showSplash: $showSplash)
                    .transition(.opacity)
            } else {
                if hasCompletedOnboarding {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
        }
        .animation(.easeOut(duration: 0.3), value: showSplash)
        .task {
            guard !isAnyTesting else { return }
            let granted = await checkPermissionsGranted()

            // 既に onboarding 完了済みなら拒否されていても再度オンボーディングへ戻さない
            // （旧実装は hasCompletedOnboarding=false に戻していたが、これが
            //  オンボーディング後に Settings で拒否したユーザを無限ループに陥らせていた。
            //  権限不足は SettingsView の Permissions 行から誘導する）。
            if granted && hasCompletedOnboarding {
                LocationManager.shared.requestAuthorization()
            }
        }
    }

    private func checkPermissionsGranted() async -> Bool {
        let locStatus = CLLocationManager().authorizationStatus
        let locGranted = locStatus == .authorizedWhenInUse || locStatus == .authorizedAlways

        // タイムアウト付きで通知設定を取得（テスト環境でのハング防止）
        let notifGranted: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let s = await UNUserNotificationCenter.current().notificationSettings()
                return s.authorizationStatus == .authorized
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒タイムアウト
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        return locGranted && notifGranted
    }
}

// MARK: - Splash Content

private struct SplashContent: View {
    @Binding var showSplash: Bool

    @State private var pinOffset: CGFloat = -300
    @State private var pinOpacity: Double = 0
    @State private var textOpacity: Double = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 18/255, green: 8/255, blue: 68/255),
                         Color(red: 48/255, green: 20/255, blue: 120/255)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                // Pin Icon
                GeoMemoIconView(size: 120)
                    .offset(y: pinOffset)
                    .opacity(pinOpacity)

                // Text
                VStack(spacing: 8) {
                    Text(verbatim: "GEOMEMO")
                        .font(.title.weight(.bold))
                        .foregroundColor(.white)

                    Text("Leave memos at places")
                        .font(.footnote)
                        .tracking(1)
                        .foregroundColor(.white.opacity(0.5))
                }
                .opacity(textOpacity)
            }
        }
        // .task は view 寿命に紐付くので、splash がバックグラウンド遷移などで
        // 早期に消えた場合に sleep もキャンセルされる（旧 asyncAfter は cancel 不可だった）。
        .task {
            withAnimation(
                .spring(
                    response: 0.6,
                    dampingFraction: 0.5,
                    blendDuration: 0
                )
            ) {
                pinOffset = 0
                pinOpacity = 1
            }

            // Text fades in with delay
            withAnimation(
                .easeIn(duration: 0.4)
                .delay(0.4)
            ) {
                textOpacity = 1
            }

            // Haptic when pin lands (0.6s 後)
            try? await Task.sleep(for: .seconds(0.6))
            HapticManager.impact(.medium)

            // Transition to main content (0.6s + 1.6s = 2.2s after start)
            try? await Task.sleep(for: .seconds(1.6))
            showSplash = false
        }
    }
}

// Brand colors and Color(hex:) are defined in Theme.swift

// MARK: - Preview

#Preview {
    SplashView()
        .modelContainer(for: GeoMemo.self, inMemory: true)
}

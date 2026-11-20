import SwiftUI
import SwiftData

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

            // 起動時に許可ダイアログは出さない（旧実装は「常に許可」を要求し直していた）。
            // 許可が足りない場合は、地図のバナーから本人の操作で案内する。
            // ここでは許可済みのときの現在地・方位のウォームアップだけ行う。
            if hasCompletedOnboarding {
                LocationManager.shared.warmUp()
            }
        }
    }
}

// MARK: - Splash Content

private struct SplashContent: View {
    @Binding var showSplash: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            if reduceMotion {
                // 動きを減らす設定: ピンは跳ねずにフェードインだけ
                pinOffset = 0
                withAnimation(.easeIn(duration: 0.25)) {
                    pinOpacity = 1
                    textOpacity = 1
                }
            } else {
                withAnimation(
                    .spring(
                        response: 0.4,
                        dampingFraction: 0.6,
                        blendDuration: 0
                    )
                ) {
                    pinOffset = 0
                    pinOpacity = 1
                }

                // Text fades in with delay
                withAnimation(
                    .easeIn(duration: 0.25)
                    .delay(0.2)
                ) {
                    textOpacity = 1
                }

                // Haptic when pin lands (0.4s 後)
                try? await Task.sleep(for: .seconds(0.4))
                HapticManager.impact(.medium)
            }

            // Transition to main content。フェード (0.3s) を含めて 1 秒以内に収める
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.7 : 0.3))
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

import SwiftUI
import SwiftData
import CoreLocation
import UserNotifications

struct SplashView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showSplash = true

    var body: some View {
        ZStack {
            if showSplash {
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
            let granted = await checkPermissionsGranted()

            if granted && hasCompletedOnboarding {
                LocationManager.shared.requestAuthorization()
            } else if !granted {
                hasCompletedOnboarding = false
            }
        }
    }

    private func checkPermissionsGranted() async -> Bool {
        let locStatus = CLLocationManager().authorizationStatus
        let locGranted = locStatus == .authorizedWhenInUse || locStatus == .authorizedAlways

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let notifGranted = settings.authorizationStatus == .authorized

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
            Brand.blue
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // Pin Icon
                GeoMemoIconView(size: 120)
                    .offset(y: pinOffset)
                    .opacity(pinOpacity)

                // Text
                VStack(spacing: 8) {
                    Text(verbatim: "GEOMEMO")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)

                    Text(verbatim: "ARCHITECTURAL MEMORY ENGINE")
                        .font(.system(size: 12, weight: .regular))
                        .tracking(3)
                        .foregroundColor(.white.opacity(0.6))
                }
                .opacity(textOpacity)
            }
        }
        .onAppear {
            // Pin drops from top with bounce
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

            // Haptic when pin lands
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                HapticManager.impact(.medium)
            }

            // Text fades in with delay
            withAnimation(
                .easeIn(duration: 0.4)
                .delay(0.4)
            ) {
                textOpacity = 1
            }

            // Transition to main content
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                showSplash = false
            }
        }
    }
}

// MARK: - Map Pin Shape

private struct MapPinShape: View {
    var body: some View {
        ZStack {
            Circle()
                .frame(width: 56, height: 56)
                .offset(y: -20)

            Triangle()
                .frame(width: 28, height: 32)
                .offset(y: 18)
        }
        .foregroundColor(.white)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// Brand colors and Color(hex:) are defined in Theme.swift

// MARK: - Preview

#Preview {
    SplashView()
        .modelContainer(for: GeoMemo.self, inMemory: true)
}

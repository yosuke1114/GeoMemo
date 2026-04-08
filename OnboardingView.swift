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
    @State private var currentPage = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                welcomeContent.tag(0)
                locationContent.tag(1)
                notificationContent.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Page indicator
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index == currentPage ? Brand.blue : Brand.inactiveIndicator)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .padding(.bottom, 32)
            .accessibilityLabel("Page \(currentPage + 1) of 3")

            // Action area
            VStack(spacing: 0) {
                primaryButton(
                    title: currentPage == 0 ? String(localized: "Get Started") : String(localized: "Allow"),
                    action: handlePrimaryAction
                )

                if currentPage > 0 {
                    Button(action: handleSkip) {
                        Text("Set up later")
                            .font(.system(size: 14))
                            .foregroundColor(Brand.secondaryText)
                    }
                    .padding(.top, 12)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: currentPage)
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
        .background(Brand.background)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Step 1: Welcome

    private var welcomeContent: some View {
        VStack(spacing: 0) {
            Spacer()

            GeoMemoIconView(size: 100)
                .padding(.bottom, 16)

            Text("GEOMEMO")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(Brand.primaryText)
                .padding(.bottom, 8)

            Text("Leave memos at places")
                .font(.system(size: 16))
                .foregroundColor(Brand.secondaryText)

            Spacer()
        }
    }

    // MARK: - Step 2: Location Permission

    private var locationContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("GeoMemo")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Brand.primaryText)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer()

            Image("ph-navigation-arrow-fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundColor(Brand.blue)
                .padding(.bottom, 24)

            Text("Allow Location")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Brand.primaryText)
                .padding(.bottom, 12)

            Text("Used to notify you when\nyou approach a memo area")
                .font(.system(size: 15))
                .foregroundColor(Brand.secondaryText)
                .multilineTextAlignment(.center)

            Spacer()
        }
    }

    // MARK: - Step 3: Notification Permission

    private var notificationContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("GeoMemo")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Brand.primaryText)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer()

            Image("ph-bell-fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundColor(Brand.blue)
                .padding(.bottom, 24)

            Text("Allow Notifications")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Brand.primaryText)
                .padding(.bottom, 12)

            Text("Get notified when you enter\nor leave a saved location")
                .font(.system(size: 15))
                .foregroundColor(Brand.secondaryText)
                .multilineTextAlignment(.center)

            Spacer()
        }
    }

    // MARK: - Components

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Brand.blue)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func handlePrimaryAction() {
        HapticManager.impact(.light)
        switch currentPage {
        case 0:
            withAnimation { currentPage = 1 }
        case 1:
            LocationManager.shared.requestAuthorization()
            withAnimation { currentPage = 2 }
        case 2:
            Task {
                _ = await NotificationManager.shared.requestAuthorization()
                hasCompletedOnboarding = true
            }
        default:
            break
        }
    }

    private func handleSkip() {
        HapticManager.selection()
        switch currentPage {
        case 1:
            withAnimation { currentPage = 2 }
        case 2:
            hasCompletedOnboarding = true
        default:
            break
        }
    }
}

// Brand colors and Color(hex:) are defined in Theme.swift

// MARK: - Preview

#Preview {
    OnboardingView()
}

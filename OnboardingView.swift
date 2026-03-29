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

    private let brandBlue = Color(hex: "3D3BF3")
    private let brandBlack = Color(hex: "1A1A1A")

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
                        .fill(index == currentPage ? brandBlue : Color(hex: "D0D0D0"))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 32)

            // Action area
            VStack(spacing: 0) {
                primaryButton(
                    title: currentPage == 0 ? "はじめる" : "許可する",
                    action: handlePrimaryAction
                )

                if currentPage > 0 {
                    Button(action: handleSkip) {
                        Text("あとで設定する")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 12)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: currentPage)
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
        .background(Color.white)
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
                .foregroundColor(brandBlack)
                .padding(.bottom, 8)

            Text("場所にメモを残そう")
                .font(.system(size: 16))
                .foregroundColor(.gray)

            Spacer()
        }
    }

    // MARK: - Step 2: Location Permission

    private var locationContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("GeoMemo")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(brandBlack)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer()

            Image("ph-navigation-arrow-fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundColor(brandBlue)
                .padding(.bottom, 24)

            Text("位置情報を許可")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(brandBlack)
                .padding(.bottom, 12)

            Text("エリアに近づいたときにメモをお知らせ\nするために使用します")
                .font(.system(size: 15))
                .foregroundColor(.gray)
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
                    .foregroundColor(brandBlack)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer()

            Image("ph-bell-fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundColor(brandBlue)
                .padding(.bottom, 24)

            Text("通知を許可")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(brandBlack)
                .padding(.bottom, 12)

            Text("登録した場所に近づいたとき・\n離れたときにお知らせします")
                .font(.system(size: 15))
                .foregroundColor(.gray)
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
                .background(brandBlue)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func handlePrimaryAction() {
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
    OnboardingView()
}

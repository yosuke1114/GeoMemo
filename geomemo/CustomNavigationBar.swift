import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import CloudKit

// 上部のナビゲーションバー。ContentView.swift から分離。

// MARK: - Custom Navigation Bar
struct CustomNavigationBar: View {
    let memoCount: Int
    @Binding var showSettings: Bool
    @Binding var isSearching: Bool
    @Binding var showWatchDashboard: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Logo Icon
            Image("ph-map-trifold-fill")
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundColor(Brand.blue)
            
            // Logo Text
            Text(verbatim: "GEOMEMO")
                .font(.title2.weight(.heavy))
                .foregroundColor(Brand.primaryText)
                // 狭い幅（折りたたみ端末のカバー画面・大きな文字サイズ）でロゴが
                // 「GEOMEM / O」と折り返さないよう 1 行に固定して縮小で収める
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer()
            
            // Memo Count Badge (only show if count > 0)
            if memoCount > 0 {
                Text(String(format: "%02d", memoCount))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Brand.primaryText)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: memoCount)
                    .frame(width: 40, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Brand.border, lineWidth: 1.5)
                    )
                    .accessibilityLabel("\(memoCount) memos")
            }
            
            // Watch Dashboard Button
            Button(action: { showWatchDashboard = true }) {
                Image(systemName: "eye")
                    .font(.body.weight(.medium))
                    .foregroundColor(Brand.primaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(String(localized: "見守り"))

            // Search Button
            Button(action: { withAnimation(.easeInOut(duration: 0.25)) { isSearching.toggle() } }) {
                Image("ph-magnifying-glass-bold")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundColor(Brand.primaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(String(localized: "Search"))

            // Settings Button
            Button(action: { showSettings = true }) {
                Image("ph-gear-six-bold")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundColor(Brand.primaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(String(localized: "Settings"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Brand.background)
        .overlay(
            Rectangle()
                .fill(Brand.border)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

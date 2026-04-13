import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = StoreKitManager.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {

                    // MARK: Hero
                    VStack(spacing: 12) {
                        Image("ph-map-pin-fill")
                            .resizable()
                            .frame(width: 48, height: 48)
                            .foregroundStyle(Brand.blue)
                            .padding(.top, 40)

                        Text("GEOMEMO PRO")
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundStyle(Brand.primaryText)

                        Text(String(localized: "Unlock unlimited memos"))
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Brand.secondaryText)
                    }
                    .padding(.bottom, 40)

                    // MARK: Feature List
                    VStack(spacing: 0) {
                        featureRow(
                            icon: "ph-infinity",
                            title: String(localized: "Unlimited Memos"),
                            subtitle: String(localized: "Free plan is limited to \(GeoMemoLimits.freeMemoLimit) memos")
                        )
                        Divider()
                            .background(Brand.primaryText.opacity(0.08))
                            .padding(.horizontal, 20)

                        featureRow(
                            icon: "ph-map-trifold",
                            title: String(localized: "Route Trigger"),
                            subtitle: String(localized: "Notify when passing waypoints in order")
                        )
                        Divider()
                            .background(Brand.primaryText.opacity(0.08))
                            .padding(.horizontal, 20)

                        featureRow(
                            icon: "ph-check-square",
                            title: String(localized: "List / Checklist Mode"),
                            subtitle: String(localized: "Manage shopping lists and tasks by location")
                        )
                        Divider()
                            .background(Brand.primaryText.opacity(0.08))
                            .padding(.horizontal, 20)

                        featureRow(
                            icon: "ph-map-pin-fill",
                            title: String(localized: "Pass-Through (Dynamic Island)"),
                            subtitle: String(localized: "See distance in Dynamic Island when nearby")
                        )
                    }
                    .background(Brand.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20)

                    // MARK: Price & Purchase
                    VStack(spacing: 12) {
                        if let product = store.proProduct {
                            Text(product.displayPrice)
                                .font(.system(size: 36, weight: .heavy, design: .monospaced))
                                .foregroundStyle(Brand.primaryText)

                            Text(String(localized: "One-time purchase · No subscription"))
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(Brand.tertiaryText)
                        } else {
                            ProgressView()
                                .tint(Brand.blue)
                        }
                    }
                    .padding(.top, 36)
                    .padding(.bottom, 24)

                    // MARK: Error
                    if let error = store.purchaseError {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "E5484D"))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }

                    // MARK: Purchase Button
                    Button(action: {
                        HapticManager.impact(.medium)
                        Task { await store.purchase() }
                    }) {
                        ZStack {
                            if store.purchaseInProgress {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text(String(localized: "Upgrade to Pro"))
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Brand.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(store.purchaseInProgress || store.proProduct == nil)
                    .padding(.horizontal, 20)

                    // MARK: Restore
                    Button(action: {
                        Task { await store.restore() }
                    }) {
                        Text(String(localized: "Restore Purchase"))
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Brand.secondaryText)
                            .underline()
                    }
                    .padding(.top, 16)
                    .disabled(store.purchaseInProgress)

                    // MARK: Legal
                    Text(String(localized: "Payment is charged to your Apple ID account. The purchase is non-refundable."))
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.tertiaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 24)
                        .padding(.bottom, 40)
                }
            }
            .background(Brand.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image("ph-x-bold")
                            .resizable()
                            .frame(width: 18, height: 18)
                            .foregroundStyle(Brand.primaryText)
                    }
                }
            }
            .onChange(of: store.isPro) { _, isPro in
                if isPro { dismiss() }
            }
        }
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(icon)
                .resizable()
                .frame(width: 22, height: 22)
                .foregroundStyle(Brand.blue)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.primaryText)
                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Brand.secondaryText)
            }

            Spacer()

            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Brand.blue)
                .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

#Preview {
    PaywallView()
}

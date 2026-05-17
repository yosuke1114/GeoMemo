import StoreKit
import SwiftUI
import Combine

// MARK: - StoreKitManager

@MainActor
class StoreKitManager: ObservableObject {

    static let shared = StoreKitManager()

    /// App Store Connect で登録する Non-Consumable の Product ID
    static let proProductID = "com.yokuro.geomemo.pro"

    @Published var isPro: Bool = false
    @Published var proProduct: Product?
    @Published var isLoadingProducts: Bool = true
    @Published var purchaseInProgress: Bool = false
    @Published var purchaseError: String?

    private var transactionListener: Task<Void, Error>?

    init() {
        transactionListener = listenForTransactions()
        Task {
            await loadProducts()
            await refreshProStatus()
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Product Loading

    func loadProducts() async {
        isLoadingProducts = true
        #if DEBUG
        if CommandLine.arguments.contains("-UITestEmptyProducts") {
            isLoadingProducts = false
            purchaseError = String(localized: "Product not available. Please try again later.")
            return
        }
        #endif
        do {
            let products = try await Product.products(for: [Self.proProductID])
            proProduct = products.first
            if products.isEmpty {
                purchaseError = String(localized: "Product not available. Please try again later.")
            }
        } catch {
            purchaseError = String(localized: "Failed to load product. Please check your connection and try again.")
            print("[StoreKit] Failed to load products: \(error)")
        }
        isLoadingProducts = false
    }

    // MARK: - Purchase

    func purchase() async {
        guard let product = proProduct else {
            purchaseError = String(localized: "Product not available. Please try again.")
            return
        }
        purchaseInProgress = true
        purchaseError = nil
        defer { purchaseInProgress = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                isPro = true
            case .userCancelled:
                break
            case .pending:
                purchaseError = String(localized: "Purchase is pending approval.")
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
            print("[StoreKit] Purchase failed: \(error)")
        }
    }

    // MARK: - Restore

    func restore() async {
        purchaseInProgress = true
        purchaseError = nil
        defer { purchaseInProgress = false }

        do {
            try await AppStore.sync()
            await refreshProStatus()
        } catch {
            purchaseError = error.localizedDescription
            print("[StoreKit] Restore failed: \(error)")
        }
    }

    // MARK: - Status Check

    func refreshProStatus() async {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.proProductID && transaction.revocationDate == nil {
                isPro = true
                return
            }
        }
        // 既存のトランザクションが見つからなければ Free
        #if DEBUG
        // 実機 Development build では Sandbox 課金が通せないため、
        // DEBUG ビルドではデフォルトで Pro 機能を解放して CloudKit Schema
        // 生成・QA を行えるようにする。
        // Free 状態をデバッグしたい場合は scheme の Arguments に
        // "-noProOverride" を追加すると通常の Free 動作になる。
        if !CommandLine.arguments.contains("-noProOverride") {
            isPro = true
            return
        }
        #endif
        isPro = false
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await MainActor.run { self.isPro = true }
                }
            }
        }
    }

    // MARK: - Verification

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }
}

// MARK: - Free Tier Limit

extension GeoMemoLimits {
    static let freeMemoLimit = 5
}

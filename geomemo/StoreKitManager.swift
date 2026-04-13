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
        do {
            let products = try await Product.products(for: [Self.proProductID])
            proProduct = products.first
        } catch {
            print("[StoreKit] Failed to load products: \(error)")
        }
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

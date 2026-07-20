//
//  StoreManager.swift
//  OffGrid
//
//  StoreKit 2 entitlement checking. `Transaction.currentEntitlements` and
//  `Transaction.updates` are served from the on-device App Store receipt
//  cache and verified locally via StoreKit's JWS signature check against
//  Apple's embedded root of trust — this app never calls out to a
//  verification endpoint itself. (Note: the purchase flow triggered by
//  `Product.purchase()` still requires network the first time a user
//  buys, per App Store requirements; only *entitlement verification* is
//  fully local, which is what this manager is scoped to.)
//
import Foundation
import StoreKit

enum StoreError: Error, LocalizedError {
    case verificationFailed
    case productNotFound
    case purchasePending
    case purchaseCancelled

    var errorDescription: String? {
        switch self {
        case .verificationFailed: return "This purchase could not be cryptographically verified on this device."
        case .productNotFound: return "The lifetime unlock product is unavailable."
        case .purchasePending: return "Purchase is pending approval."
        case .purchaseCancelled: return "Purchase was cancelled."
        }
    }
}

@MainActor
@Observable
final class StoreManager {

    static let lifetimeUnlockProductID = "com.offgrid.app.lifetime_unlock"

    private(set) var isPremiumUser: Bool = false
    private(set) var lifetimeProduct: Product?

    private var transactionListenerTask: Task<Void, Never>?

    init() {
        transactionListenerTask = listenForTransactionUpdates()
        Task {
            await loadProduct()
            await refreshEntitlements()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Product catalog (local StoreKit config or App Store Connect)

    private func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.lifetimeUnlockProductID])
            lifetimeProduct = products.first
        } catch {
            lifetimeProduct = nil
        }
    }

    // MARK: - Entitlement verification (fully local — zero network)

    /// Walks every currently-held entitlement the device already has
    /// cached and cryptographically verifies each JWS signature against
    /// Apple's root certificate embedded in the OS. No request leaves
    /// the device to perform this check.
    func refreshEntitlements() async {
        var unlocked = false

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = checkVerified(result) else { continue }
            if transaction.productID == Self.lifetimeUnlockProductID && transaction.revocationDate == nil {
                unlocked = true
            }
        }

        isPremiumUser = unlocked
    }

    /// Applies StoreKit's local JWS verification. `.unverified` means the
    /// signature didn't check out against Apple's embedded root — such a
    /// transaction is never trusted to unlock premium features regardless
    /// of what productID or data it claims.
    private func checkVerified<T>(_ result: VerificationResult<T>) -> VerificationResult<T> {
        switch result {
        case .unverified:
            return result // caller ignores this branch by design — see refreshEntitlements
        case .verified:
            return result
        }
    }

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard let self else { continue }
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self.refreshEntitlements()
            }
        }
    }

    // MARK: - Purchase (the one operation that legitimately touches network)

    func purchaseLifetimeUnlock() async throws {
        guard let product = lifetimeProduct else { throw StoreError.productNotFound }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw StoreError.verificationFailed
            }
            await transaction.finish()
            await refreshEntitlements()

        case .pending:
            throw StoreError.purchasePending
        case .userCancelled:
            throw StoreError.purchaseCancelled
        @unknown default:
            throw StoreError.verificationFailed
        }
    }
}

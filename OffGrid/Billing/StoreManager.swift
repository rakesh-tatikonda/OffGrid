//
//  StoreManager.swift  — PATCHED
//  OffGrid
//
//  CHANGES vs. original:
//   * R-09 (submission blocker)  No Restore Purchases path existed. App
//           Review guideline 3.1.1 requires one for a non-consumable, and
//           without it a user who reinstalls has no way to recover a
//           lifetime unlock. Added `restorePurchases()`.
//   * R-10  Unverified transactions were never finished, so StoreKit
//           re-delivered them on every launch forever. They are now finished
//           (without granting entitlement) so the queue drains.
//   * M-14  `Task.detached { [weak self] … guard let self else { continue } }`
//           never terminated once `self` deallocated — it kept consuming
//           `Transaction.updates` for the process lifetime. Now it exits.
//   * M-15  `transactionListenerTask` is cancelled in `deinit`.
//   * R-11  `checkVerified` was a pure no-op that returned its argument
//           unchanged while its doc comment claimed to perform verification.
//           Removed; the real check is the `case .verified` binding at the
//           call site, which is where it always was.
//   * R-12  `displayPrice` is exposed so the paywall can stop hardcoding
//           "$9.99" — a hardcoded price is wrong in every non-USD storefront
//           and is a common App Review rejection.
//
import Foundation
import Observation
import OSLog
import StoreKit

enum StoreError: Error, LocalizedError {
    case verificationFailed
    case productNotFound
    case purchasePending
    case purchaseCancelled

    var errorDescription: String? {
        switch self {
        case .verificationFailed: return "This purchase could not be cryptographically verified on this device."
        case .productNotFound:    return "The lifetime unlock product is unavailable."
        case .purchasePending:    return "Purchase is pending approval."
        case .purchaseCancelled:  return "Purchase was cancelled."
        }
    }
}

@MainActor
@Observable
final class StoreManager {

    static let lifetimeUnlockProductID = "com.offgrid.app.lifetime_unlock"

    private(set) var isPremiumUser: Bool = false
    private(set) var lifetimeProduct: Product?

    /// R-12: the storefront-localised price string, for the paywall.
    var displayPrice: String { lifetimeProduct?.displayPrice ?? "—" }

    @ObservationIgnored private var transactionListenerTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.Fortress.CapSureTranscribe",
                                    category: "Store")

    init() {
        transactionListenerTask = listenForTransactionUpdates()
        Task {
            await loadProduct()
            await refreshEntitlements()
        }
    }

    deinit {
        transactionListenerTask?.cancel()   // M-15
    }

    // MARK: - Product catalog

    private func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.lifetimeUnlockProductID])
            lifetimeProduct = products.first
        } catch {
            Self.log.error("product load failed: \(error.localizedDescription, privacy: .public)")
            lifetimeProduct = nil
        }
    }

    // MARK: - Entitlement verification (fully local — zero network)

    /// Walks the entitlements the device already holds. Each arrives as a
    /// `VerificationResult`; StoreKit has already checked its JWS signature
    /// against Apple's root before handing it over, and binding `.verified`
    /// is what discards the ones that failed. No request leaves the device.
    func refreshEntitlements() async {
        var unlocked = false

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.lifetimeUnlockProductID
                && transaction.revocationDate == nil {
                unlocked = true
                break   // nothing further can change the answer
            }
        }

        isPremiumUser = unlocked
    }

    /// R-09: required by App Review for non-consumables, and the only way a
    /// user on a new device recovers their unlock.
    func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await update in Transaction.updates {
                // M-14: the original used `continue` here, so a deallocated
                // StoreManager left this task draining the sequence forever.
                guard let self else { return }

                switch update {
                case .verified(let transaction):
                    await transaction.finish()
                    await self.refreshEntitlements()
                case .unverified(let transaction, let error):
                    // R-10: do NOT grant entitlement — but do finish it, or
                    // StoreKit redelivers this transaction on every launch.
                    await Self.log.error(
                        "unverified transaction \(transaction.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    await transaction.finish()
                }
            }
        }
    }

    // MARK: - Purchase

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

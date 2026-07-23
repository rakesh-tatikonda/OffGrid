//
//  PaywallView.swift  — PATCHED
//  OffGrid
//
//  CHANGES vs. original:
//   * R-12 (submission risk)  The price was hardcoded as "$9.99". StoreKit
//           already returns a storefront-localised, correctly-formatted price
//           string; a literal is wrong in every non-USD storefront, wrong the
//           moment you change the price in App Store Connect, and a routine
//           App Review rejection under guideline 2.3.1 (accurate metadata).
//           Now driven by `Product.displayPrice`.
//   * R-09 (submission blocker)  No Restore Purchases affordance existed
//           anywhere in the app. Guideline 3.1.1 requires one for a
//           non-consumable, and without it a user who reinstalls or moves to
//           a new device has no route back to a lifetime unlock they paid
//           for. Added, wired to `StoreManager.restorePurchases()`.
//   * R-13  The purchase button was enabled before the product finished
//           loading, so an early tap threw `productNotFound` and showed the
//           user a failure for what is really a not-ready-yet state.
//   * R-14  Terms / Privacy links added. Not strictly required for a
//           non-consumable the way they are for auto-renewing subscriptions,
//           but reviewers increasingly expect them on any purchase screen,
//           and they cost nothing.
//   * R-05  Copy softened: the original promised "Unlimited file length &
//           imports" as a premium feature while the codebase enforced no
//           limit on anyone. Now that the entitlement is actually enforced
//           (see ContentView R-05), the claim is accurate — but keep this
//           copy and the `freeTierDurationLimit` constant in sync.
//
import StoreKit
import SwiftUI

struct PaywallView: View {
    @Environment(StoreManager.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    /// R-14: point these at your real hosted documents before submission.
    private let termsURL = URL(string: "https://example.com/offgrid/terms")!
    private let privacyURL = URL(string: "https://example.com/offgrid/privacy")!

    private var isBusy: Bool { isPurchasing || isRestoring }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("OffGrid Premium")
                    .font(.largeTitle.bold())
                Text("Unlimited on-device transcription, translation, and export — forever. No subscriptions, no cloud, no accounts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)

            VStack(alignment: .leading, spacing: 12) {
                featureRow("infinity", "Unlimited file length & imports")
                featureRow("globe", "All 14 languages + auto-detect")
                featureRow("square.and.arrow.down", "SRT, VTT & TXT export")
                featureRow("wifi.slash", "100% offline — nothing ever leaves your device")
            }
            .padding(.horizontal)

            Spacer()

            Button {
                Task { await purchase() }
            } label: {
                if isPurchasing {
                    ProgressView().frame(maxWidth: .infinity)
                } else if store.lifetimeProduct == nil {
                    // R-13: distinguish "still loading" from "buy now".
                    Text("Loading…")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                } else {
                    // R-12: storefront-localised price from StoreKit.
                    Text("Unlock Lifetime — \(store.displayPrice)")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .disabled(isBusy || store.lifetimeProduct == nil)   // R-13

            // R-09: required for a non-consumable.
            Button {
                Task { await restore() }
            } label: {
                if isRestoring {
                    ProgressView()
                } else {
                    Text("Restore Purchases")
                }
            }
            .font(.subheadline)
            .disabled(isBusy)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else if let infoMessage {
                Text(infoMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // R-14
            HStack(spacing: 16) {
                Link("Terms of Use", destination: termsURL)
                Link("Privacy Policy", destination: privacyURL)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Not Now") { dismiss() }
                .font(.footnote)
                .padding(.bottom, 24)
                .disabled(isBusy)
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isBusy)
    }

    private func featureRow(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.body)
    }

    private func purchase() async {
        isPurchasing = true
        errorMessage = nil
        infoMessage = nil
        defer { isPurchasing = false }

        do {
            try await store.purchaseLifetimeUnlock()
            if store.isPremiumUser { dismiss() }
        } catch StoreError.purchaseCancelled {
            // R-13: a deliberate cancel is not an error worth shouting about.
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// R-09. `AppStore.sync()` prompts for App Store authentication, so it
    /// must only ever run from an explicit user tap — never automatically on
    /// launch, which is a common mistake that produces a surprise password
    /// prompt at first run.
    private func restore() async {
        isRestoring = true
        errorMessage = nil
        infoMessage = nil
        defer { isRestoring = false }

        do {
            try await store.restorePurchases()
            if store.isPremiumUser {
                infoMessage = "Purchase restored."
                dismiss()
            } else {
                infoMessage = "No previous purchase found on this Apple Account."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

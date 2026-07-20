//
//  PaywallView.swift
//  OffGrid
//
import SwiftUI

struct PaywallView: View {
    @Environment(StoreManager.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var isPurchasing = false
    @State private var errorMessage: String?

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
                } else {
                    Text("Unlock Lifetime — $9.99")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .disabled(isPurchasing)

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }

            Button("Not Now") { dismiss() }
                .font(.footnote)
                .padding(.bottom, 24)
        }
        .presentationDetents([.large])
    }

    private func featureRow(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.body)
    }

    private func purchase() async {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }
        do {
            try await store.purchaseLifetimeUnlock()
            if store.isPremiumUser { dismiss() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

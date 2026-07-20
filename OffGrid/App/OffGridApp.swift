//
//  OffGridApp.swift
//  OffGrid
//
import SwiftUI

@main
struct OffGridApp: App {

    @State private var storeManager = StoreManager()

    /// Models are expected to ship inside the app bundle (Resources/Models)
    /// so first launch never needs network to download them, matching the
    /// zero-network-inference requirement.
    private var whisperModelPath: String {
        Bundle.main.path(forResource: "ggml-small-encoder", ofType: "bin") ?? ""
    }
    private var llamaModelPath: String {
        Bundle.main.path(forResource: "gemma-2b-q4_k_m", ofType: "gguf") ?? ""
    }

    var body: some Scene {
        WindowGroup {
            ContentView(whisperModelPath: whisperModelPath, llamaModelPath: llamaModelPath)
                .modelContainer(PersistenceController.shared.container)
                .environment(storeManager)
        }
    }
}

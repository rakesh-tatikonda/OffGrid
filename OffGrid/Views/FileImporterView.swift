//
//  FileImporterView.swift
//  OffGrid
//
//  Native Files-app document picker. Never requests the Photos or
//  broader storage permission — `.fileImporter` uses the system's own
//  security-scoped bookmark mechanism, so OffGrid only ever gains
//  access to the exact file the user selects, for exactly as long as
//  the security-scoped access block is open.
//
import SwiftUI
import UniformTypeIdentifiers

enum FileImportError: Error, LocalizedError {
    case accessDenied
    case copyFailed(Error)

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "OffGrid couldn't get permission to read that file."
        case .copyFailed(let e): return "Couldn't copy the file into the secure sandbox: \(e.localizedDescription)"
        }
    }
}

@MainActor
final class FileImportCoordinator: ObservableObject {

    @Published var isImporting = false
    @Published var lastError: FileImportError?

    static let supportedMediaTypes: [UTType] = [
        .mpeg4Movie, .quickTimeMovie, .movie,
        .mp3, .wav, .mpeg4Audio, .audio
    ]

    /// Performs the full security-scoped handshake and returns metadata
    /// for a copy of the file living inside OffGrid's own encrypted
    /// sandbox cache — the caller hands `sandboxURL` straight to
    /// `AudioPipeline.extractPCM(from:)`.
    func importFile(from result: Result<URL, Error>) throws -> IngestedMedia {
        let sourceURL: URL
        switch result {
        case .success(let url): sourceURL = url
        case .failure(let error): throw error
        }

        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw FileImportError.accessDenied
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }

        let sandboxURL = SandboxPaths.newSandboxURL(preservingExtensionOf: sourceURL)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: sandboxURL)
        } catch {
            throw FileImportError.copyFailed(error)
        }

        return IngestedMedia(sandboxURL: sandboxURL, originalFileName: sourceURL.lastPathComponent)
    }
}

struct FileImporterButton: View {
    @StateObject private var coordinator = FileImportCoordinator()
    let onImported: (IngestedMedia) -> Void

    var body: some View {
        Button {
            coordinator.isImporting = true
        } label: {
            Label("Import from Files", systemImage: "folder.badge.plus")
        }
        .fileImporter(
            isPresented: $coordinator.isImporting,
            allowedContentTypes: FileImportCoordinator.supportedMediaTypes,
            allowsMultipleSelection: false
        ) { result in
            do {
                let singleResult = try result.map { urls in
                    guard let first = urls.first else { throw FileImportError.accessDenied }
                    return first
                }
                let media = try coordinator.importFile(from: singleResult)
                onImported(media)
            } catch let error as FileImportError {
                coordinator.lastError = error
            } catch {
                coordinator.lastError = .copyFailed(error)
            }
        }
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { coordinator.lastError != nil },
                set: { if !$0 { coordinator.lastError = nil } }
            ),
            presenting: coordinator.lastError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.errorDescription ?? "Unknown error")
        }
    }
}

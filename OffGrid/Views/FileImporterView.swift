//
//  FileImporterView.swift  — PATCHED
//  OffGrid
//
//  CHANGES vs. original:
//   * P-08 (HIGH)  `importFile` was `@MainActor` and called
//                  `FileManager.copyItem` on it. Importing a 2 GB video froze
//                  the UI for the entire copy; past ~20 s the watchdog kills
//                  the app with 0x8badf00d, which reads to the user as a
//                  random crash on large files. The copy now runs on a
//                  detached task; only the security-scope handshake and the
//                  UI state stay on the main actor.
//   * S-14        Import size ceiling. Nothing bounded how much a single
//                  import could write into Caches.
//   * S-15        The sandbox copy is created under Data Protection (via the
//                  patched SandboxPaths) and a partial copy is cleaned up on
//                  failure, so an aborted import cannot leave a plaintext
//                  fragment behind.
//   * C-03        Migrated from ObservableObject/@Published to @Observable —
//                  @Published invalidates every observing view on any change;
//                  @Observable tracks per-property reads.
//
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum FileImportError: Error, LocalizedError {
    case accessDenied
    case copyFailed(Error)
    case tooLarge(bytes: Int64, limit: Int64)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "OffGrid couldn't get permission to read that file."
        case .copyFailed(let e):
            return "Couldn't copy the file into the secure sandbox: \(e.localizedDescription)"
        case .tooLarge(_, let limit):
            return "That file is larger than the \(limit / 1_073_741_824) GB import limit."
        }
    }
}

@MainActor
@Observable
final class FileImportCoordinator {

    /// S-14
    static let maximumImportBytes: Int64 = 4 * 1_024 * 1_024 * 1_024   // 4 GB

    var isImporting = false
    var isCopying = false
    var lastError: FileImportError?

    static let supportedMediaTypes: [UTType] = [
        .mpeg4Movie, .quickTimeMovie, .movie,
        .mp3, .wav, .mpeg4Audio, .audio
    ]

    /// Performs the security-scoped handshake, then copies off the main
    /// actor. The scope must be opened and closed around the whole copy, so
    /// the handshake is passed into the detached task rather than being
    /// closed before it starts.
    func importFile(from sourceURL: URL) async throws -> IngestedMedia {
        isCopying = true
        defer { isCopying = false }

        let originalName = sourceURL.lastPathComponent
        let destination = SandboxPaths.newSandboxURL(preservingExtensionOf: sourceURL)
        let limit = Self.maximumImportBytes

        // P-08: the copy itself is the expensive part and it does not touch
        // any main-actor state.
        try await Task.detached(priority: .userInitiated) {
            guard sourceURL.startAccessingSecurityScopedResource() else {
                throw FileImportError.accessDenied
            }
            defer { sourceURL.stopAccessingSecurityScopedResource() }

            // S-14: check before copying, not after.
            let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey])
            if let size = values?.fileSize, Int64(size) > limit {
                throw FileImportError.tooLarge(bytes: Int64(size), limit: limit)
            }

            do {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                // S-15: belt and braces on top of the directory's inherited
                // protection class.
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUnlessOpen],
                    ofItemAtPath: destination.path
                )
            } catch let error as FileImportError {
                throw error
            } catch {
                // S-15: never leave a truncated copy behind.
                try? FileManager.default.removeItem(at: destination)
                throw FileImportError.copyFailed(error)
            }
        }.value

        return IngestedMedia(sandboxURL: destination, originalFileName: originalName)
    }
}

struct FileImporterButton: View {
    @State private var coordinator = FileImportCoordinator()
    let onImported: (IngestedMedia) -> Void

    var body: some View {
        Button {
            coordinator.isImporting = true
        } label: {
            if coordinator.isCopying {
                HStack {
                    ProgressView()
                    Text("Copying…")
                }
            } else {
                Label("Import from Files", systemImage: "folder.badge.plus")
            }
        }
        .disabled(coordinator.isCopying)
        .fileImporter(
            isPresented: $coordinator.isImporting,
            allowedContentTypes: FileImportCoordinator.supportedMediaTypes,
            allowsMultipleSelection: false
        ) { result in
            Task {
                do {
                    let urls = try result.get()
                    guard let first = urls.first else { throw FileImportError.accessDenied }
                    let media = try await coordinator.importFile(from: first)
                    onImported(media)
                } catch let error as FileImportError {
                    coordinator.lastError = error
                } catch {
                    coordinator.lastError = .copyFailed(error)
                }
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

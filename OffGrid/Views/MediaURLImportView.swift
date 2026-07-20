//
//  MediaURLImportView.swift
//  OffGrid
//
//  Module 1's UI half: paste a raw media URL, stream it through the
//  single restricted network egress point (URLStreamDownloader), and
//  show real-time progress. Once the download finishes, the file is
//  moved into the same sandbox cache the Files-app importer uses, so
//  both ingestion paths converge on one `IngestedMedia` value and the
//  rest of the app can't tell them apart.
//
import SwiftUI

enum URLImportState: Equatable {
    case idle
    case downloading(progress: Double)
    case failed(String)
}

@MainActor
final class URLImportCoordinator: ObservableObject {

    @Published var state: URLImportState = .idle
    @Published var urlText: String = ""

    private let downloader = URLStreamDownloader()
    private var activeTask: Task<Void, Never>?

    var isBusy: Bool {
        if case .downloading = state { return true }
        return false
    }

    func startDownload(onFinished: @escaping (IngestedMedia) -> Void) {
        guard let remoteURL = URL(string: urlText), remoteURL.scheme == "https" else {
            state = .failed("Enter a valid https:// media URL.")
            return
        }

        let originalName = remoteURL.lastPathComponent.isEmpty ? "download" : remoteURL.lastPathComponent
        state = .downloading(progress: 0)

        activeTask = Task {
            do {
                let stream = await downloader.download(from: remoteURL)
                for try await update in stream {
                    switch update {
                    case .idle:
                        continue
                    case .downloading(let progress):
                        state = .downloading(progress: progress)
                    case .finished(let temporaryFileURL):
                        let sandboxURL = SandboxPaths.newSandboxURL(preservingExtensionOf: remoteURL)
                        try FileManager.default.moveItem(at: temporaryFileURL, to: sandboxURL)
                        state = .idle
                        urlText = ""
                        onFinished(IngestedMedia(sandboxURL: sandboxURL, originalFileName: originalName))
                    case .failed(let message):
                        state = .failed(message)
                    }
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        activeTask?.cancel()
        state = .idle
    }
}

struct MediaURLImportView: View {
    @StateObject private var coordinator = URLImportCoordinator()
    let onImported: (IngestedMedia) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Paste media URL (https://…)", text: $coordinator.urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(coordinator.isBusy)

                Button(coordinator.isBusy ? "Cancel" : "Fetch") {
                    if coordinator.isBusy {
                        coordinator.cancel()
                    } else {
                        coordinator.startDownload(onFinished: onImported)
                    }
                }
                .disabled(!coordinator.isBusy && coordinator.urlText.isEmpty)
            }

            switch coordinator.state {
            case .idle:
                EmptyView()
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text("Downloading… \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

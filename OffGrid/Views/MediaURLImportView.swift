//
//  MediaURLImportView.swift  — PATCHED
//  OffGrid
//
//  CHANGES vs. original:
//   * M-11  Strong reference cycle. `activeTask` is stored on `self`, and the
//           Task closure captured `self` strongly (implicitly, via
//           `state = …`). self → activeTask → closure → self. Combined with
//           M-12 below, the coordinator could be retained for the app's
//           lifetime. Now `[weak self]`.
//   * M-12  The `for await` loop had a `.failed` case that set state and kept
//           iterating. Because the downloader signalled real failures via
//           `finish(throwing:)` and never yielded `.failed`, that branch was
//           unreachable — but the loop also had no exit on the state the UI
//           treated as terminal, so a stalled stream held the task (and the
//           cycle) open indefinitely.
//   * M-13  `activeTask` is cleared on completion and cancelled in `deinit`.
//   * C-04  Cancel now actually cancels the transfer. Previously it cancelled
//           only the Swift Task; the URLSession download continued to
//           completion, burning cellular data and battery, and its finished
//           file was orphaned on disk with no scrub path. The fix is the
//           `onTermination` handler added in the patched URLStreamDownloader.
//   * S-16  Input is trimmed and validated more strictly before use.
//   * C-03  ObservableObject/@Published → @Observable.
//
import Observation
import SwiftUI

enum URLImportState: Equatable {
    case idle
    case downloading(progress: Double)
    case failed(String)
}

@MainActor
@Observable
final class URLImportCoordinator {

    var state: URLImportState = .idle
    var urlText: String = ""

    private let downloader = URLStreamDownloader()
    @ObservationIgnored private var activeTask: Task<Void, Never>?

    var isBusy: Bool {
        if case .downloading = state { return true }
        return false
    }

    deinit {
        activeTask?.cancel()   // M-13
    }

    func startDownload(onFinished: @escaping (IngestedMedia) -> Void) {
        // S-16: a pasted URL routinely carries surrounding whitespace.
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let remoteURL = URL(string: trimmed),
              remoteURL.scheme?.lowercased() == "https",
              let host = remoteURL.host, !host.isEmpty else {
            state = .failed("Enter a valid https:// media URL.")
            return
        }

        let originalName = remoteURL.lastPathComponent.isEmpty ? "download" : remoteURL.lastPathComponent
        state = .downloading(progress: 0)

        activeTask?.cancel()

        // M-11: weak capture breaks self → activeTask → closure → self.
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await self.downloader.download(from: remoteURL)
                for try await update in stream {
                    if Task.isCancelled { break }
                    switch update {
                    case .idle:
                        continue
                    case .downloading(let progress):
                        self.state = .downloading(progress: progress)
                    case .finished(let sandboxURL):
                        // The patched downloader already lands the payload in
                        // the Data-Protected ingest directory, so there is no
                        // second move here — one less window in which a
                        // plaintext copy exists outside protection.
                        self.state = .idle
                        self.urlText = ""
                        onFinished(IngestedMedia(sandboxURL: sandboxURL,
                                                 originalFileName: originalName))
                        // M-12: terminal state, stop iterating.
                        self.activeTask = nil
                        return
                    }
                }
                if !Task.isCancelled, self.isBusy { self.state = .idle }
            } catch is CancellationError {
                self.state = .idle
            } catch {
                self.state = .failed(error.localizedDescription)
            }
            self.activeTask = nil   // M-13
        }
    }

    /// C-04: cancelling the Task tears down the AsyncThrowingStream, which
    /// fires `onTermination` in URLStreamDownloader, which cancels the
    /// underlying URLSessionDownloadTask. In the original, none of that
    /// second half happened.
    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        state = .idle
    }
}

struct MediaURLImportView: View {
    @State private var coordinator = URLImportCoordinator()
    let onImported: (IngestedMedia) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Paste media URL (https://…)", text: $coordinator.urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
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

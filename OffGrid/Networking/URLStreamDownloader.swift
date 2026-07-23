//
//  URLStreamDownloader.swift  — PATCHED
//  OffGrid
//
//  The ONLY place in OffGrid permitted to open a network connection.
//
//  CHANGES vs. original:
//   * S-07  Redirects are now re-validated. The original checked the scheme
//           of the URL the user typed and then let URLSession follow any
//           redirect chain it was handed, including into private/loopback
//           address space.
//   * S-08  HTTP status and Content-Length are validated before the body is
//           accepted. The original moved a 404 error page onto disk and
//           handed it downstream as "media".
//   * S-09  A hard byte ceiling is enforced during transfer, so a server
//           that streams indefinitely cannot fill the device.
//   * S-10  The finished file lands in the protected ingest directory under
//           Data Protection, not in bare tmp/.
//   * M-04  `onTermination` now cancels the URLSessionTask and drops the
//           continuation. The original leaked one dictionary entry and one
//           live download per cancelled request — the "Cancel" button in
//           MediaURLImportView did not actually stop the transfer.
//   * C-01  Session/continuation state is no longer touched from inside the
//           `@Sendable` AsyncThrowingStream build closure (a strict-
//           concurrency error under Swift 6 language mode).
//   * B-01  Expensive/constrained network access is opt-out by default, so
//           a multi-hundred-MB fetch does not silently run over cellular or
//           in Low Data Mode.
//
import Foundation
import OSLog

enum DownloadState: Equatable {
    case idle
    case downloading(progress: Double)
    case finished(fileURL: URL)
}

enum DownloadError: LocalizedError {
    case insecureScheme
    case redirectBlocked(String)
    case badStatus(Int)
    case tooLarge(bytes: Int64, limit: Int64)

    var errorDescription: String? {
        switch self {
        case .insecureScheme:
            return "Only https:// URLs can be fetched."
        case .redirectBlocked(let host):
            return "That link redirected somewhere OffGrid will not follow (\(host))."
        case .badStatus(let code):
            return "The server responded with HTTP \(code)."
        case .tooLarge(_, let limit):
            return "That file is larger than the \(limit / 1_048_576) MB download limit."
        }
    }
}

protocol MediaDownloading: Actor {
    func download(from remoteURL: URL) -> AsyncThrowingStream<DownloadState, Error>
}

actor URLStreamDownloader: MediaDownloading {

    /// S-09: ceiling on any single fetch.
    static let maximumDownloadBytes: Int64 = 2 * 1_024 * 1_024 * 1_024   // 2 GB

    private static let log = Logger(subsystem: "com.Fortress.CapSureTranscribe",
                                    category: "Downloader")

    private lazy var restrictedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // B-01: was `true` for both. Large media over a metered or
        // Low-Data-Mode link is exactly what these flags exist to prevent.
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.waitsForConnectivity = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        // Explicit floor rather than relying on the platform default, so a
        // future deployment-target change cannot quietly widen it.
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config, delegate: delegateRelay, delegateQueue: nil)
    }()

    private let delegateRelay = SessionDelegateRelay()

    private struct Pending {
        let continuation: AsyncThrowingStream<DownloadState, Error>.Continuation
        let task: URLSessionDownloadTask
    }
    private var pending: [Int: Pending] = [:]

    init() {
        delegateRelay.owner = self
    }

    func download(from remoteURL: URL) -> AsyncThrowingStream<DownloadState, Error> {
        // C-01: `makeStream()` hands back the continuation directly, so the
        // actor's isolated state is mutated here in ordinary isolated context.
        // The original mutated `continuations` and read `restrictedSession`
        // from inside the `AsyncThrowingStream { ... }` build closure, which
        // is @Sendable — an error under Swift 6 language mode and a data race
        // in Swift 5 mode.
        let (stream, continuation) = AsyncThrowingStream<DownloadState, Error>.makeStream()
        start(remoteURL, continuation: continuation)
        return stream
    }

    private func start(_ remoteURL: URL,
                       continuation: AsyncThrowingStream<DownloadState, Error>.Continuation) {
        guard remoteURL.scheme?.lowercased() == "https" else {
            continuation.finish(throwing: DownloadError.insecureScheme)
            return
        }

        let task = restrictedSession.downloadTask(with: remoteURL)
        let id = task.taskIdentifier
        pending[id] = Pending(continuation: continuation, task: task)

        // M-04: this is the fix for the dead Cancel button. When the consumer
        // stops iterating — explicitly, or by its Task being cancelled — the
        // transfer is torn down and the slot released. Without it the download
        // ran to completion in the background and its file was orphaned in
        // tmp/ with no scrub path.
        continuation.onTermination = { [weak self] _ in
            Task { await self?.retire(taskID: id, cancelTransfer: true) }
        }

        continuation.yield(.idle)
        task.resume()
    }

    fileprivate func emitProgress(_ fraction: Double, forTaskID id: Int) {
        pending[id]?.continuation.yield(.downloading(progress: fraction))
    }

    fileprivate func complete(with fileURL: URL, forTaskID id: Int) {
        guard let entry = pending[id] else {
            // Consumer already went away; do not leave the payload on disk.
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        entry.continuation.yield(.finished(fileURL: fileURL))
        entry.continuation.finish()
        pending[id] = nil
    }

    fileprivate func fail(_ error: Error, forTaskID id: Int) {
        pending[id]?.continuation.finish(throwing: error)
        pending[id] = nil
    }

    private func retire(taskID id: Int, cancelTransfer: Bool) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        if cancelTransfer { entry.task.cancel() }
    }
}

private final class SessionDelegateRelay: NSObject, URLSessionDownloadDelegate {

    weak var owner: URLStreamDownloader?

    // S-07: re-validate every hop. URLSession follows redirects silently by
    // default, so the scheme check at request time says nothing about where
    // the bytes actually come from. Completing the handler with `nil` refuses
    // the redirect without failing the app.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !Self.isPrivateOrLoopback(host) else {
            let id = task.taskIdentifier
            let host = request.url?.host ?? "unknown host"
            completionHandler(nil)
            Task { [owner] in await owner?.fail(DownloadError.redirectBlocked(host), forTaskID: id) }
            return
        }
        completionHandler(request)
    }

    // NOTE on where S-08/S-09 are enforced:
    //
    // `urlSession(_:dataTask:didReceive:completionHandler:)` — the obvious
    // place to vet a response before its body arrives — belongs to
    // `URLSessionDataDelegate`, which `URLSessionDownloadDelegate` does NOT
    // inherit from. Implementing it on a download-task delegate produces a
    // method that compiles, looks correct in review, and is never called.
    //
    // For download tasks the earliest reliable hook is the first
    // `didWriteData` callback, where `downloadTask.response` is already
    // populated. The checks therefore live there, with a final backstop in
    // `didFinishDownloadingTo`.

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier

        // S-08: reject a non-2xx response as soon as headers are available,
        // rather than letting a 404 error page land on disk as "media".
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            downloadTask.cancel()
            Task { [owner] in await owner?.fail(DownloadError.badStatus(http.statusCode), forTaskID: id) }
            return
        }

        // S-09: honour a declared Content-Length up front...
        if totalBytesExpectedToWrite > 0,
           totalBytesExpectedToWrite > URLStreamDownloader.maximumDownloadBytes {
            downloadTask.cancel()
            Task { [owner] in
                await owner?.fail(
                    DownloadError.tooLarge(bytes: totalBytesExpectedToWrite,
                                           limit: URLStreamDownloader.maximumDownloadBytes),
                    forTaskID: id
                )
            }
            return
        }

        // ...and enforce on the running total too, since a chunked response
        // declares no length at all.
        if totalBytesWritten > URLStreamDownloader.maximumDownloadBytes {
            downloadTask.cancel()
            Task { [owner] in
                await owner?.fail(
                    DownloadError.tooLarge(bytes: totalBytesWritten,
                                           limit: URLStreamDownloader.maximumDownloadBytes),
                    forTaskID: id
                )
            }
            return
        }

        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        Task { [owner] in await owner?.emitProgress(progress, forTaskID: id) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp URL is valid only for the duration of this callback, so
        // the move must complete synchronously here, before any await hop.
        let id = downloadTask.taskIdentifier

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            Task { [owner] in await owner?.fail(DownloadError.badStatus(http.statusCode), forTaskID: id) }
            return
        }

        // S-10: land in the Data-Protected ingest directory rather than bare
        // tmp/, so the payload is encrypted at rest from the moment it exists
        // and is covered by the orphan sweep.
        let destination = SandboxPaths.newSandboxURL(preservingExtensionOf: downloadTask.originalRequest?.url ?? location)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: destination.path
            )
            Task { [owner] in await owner?.complete(with: destination, forTaskID: id) }
        } catch {
            Task { [owner] in await owner?.fail(error, forTaskID: id) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskIdentifier
        Task { [owner] in await owner?.fail(error, forTaskID: id) }
    }

    /// S-07: coarse private-range check. Not a substitute for a full SSRF
    /// guard, but it stops the common cases — a shortener or an open
    /// redirector pointing the app at something on the user's own LAN.
    private static func isPrivateOrLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") { return true }
        if h == "::1" || h == "[::1]" { return true }
        let parts = h.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _):                       return true
        case (127, _):                      return true
        case (169, 254):                    return true   // link-local
        case (192, 168):                    return true
        case (172, 16...31):                return true
        default:                            return false
        }
    }
}

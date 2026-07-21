//
//  URLStreamDownloader.swift
//  OffGrid
//
//  This file is the ONLY place in OffGrid permitted to open a network
//  connection. The URLSessionConfiguration below is deliberately
//  crippled: ephemeral (no cookie/cache persistence across launches),
//  no background transfers, no waiting for connectivity, and no shared
//  container — so nothing about a fetch can be replayed, resumed after
//  app suspension, or used as a side-channel for telemetry.
//
//  Enforce at the project level too: Info.plist should NOT include any
//  `UIBackgroundModes` entries, and `NSAppTransportSecurity` should be
//  left at its secure default (no `NSAllowsArbitraryLoads`), so this
//  session's TLS requirements can't be relaxed by a config change
//  elsewhere in the app.
//
import Foundation

enum DownloadState: Equatable {
    case idle
    case downloading(progress: Double)
    case finished(fileURL: URL)
    case failed(String)
}

protocol MediaDownloading: Actor {
    func download(from remoteURL: URL) -> AsyncThrowingStream<DownloadState, Error>
}

actor URLStreamDownloader: MediaDownloading {

    /// The single, restricted session used for all raw media fetches.
    /// Never reuse `URLSession.shared` elsewhere in the app — every
    /// other subsystem should be unreachable from the network entirely.
    private lazy var restrictedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = false          // no silent background retries
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.httpShouldSetCookies = false
        // A URLSession delegate MUST be an NSObject subclass. An `actor`
        // cannot be one — actors do not support class inheritance — so the
        // delegate role is delegated to a tiny private relay object that
        // forwards every callback back into this actor's isolated state.
        return URLSession(configuration: config, delegate: delegateRelay, delegateQueue: nil)
    }()

    /// Owns the `URLSessionDownloadDelegate` conformance on the actor's
    /// behalf. Held strongly here; it holds `self` only weakly, so there's
    /// no retain cycle even though URLSession also retains it.
    private let delegateRelay = SessionDelegateRelay()

    /// Keyed by `URLSessionTask.taskIdentifier` (unique within one session)
    /// so the nonisolated delegate callbacks can address the right stream
    /// without passing a non-Sendable task across the isolation boundary.
    private var continuations: [Int: AsyncThrowingStream<DownloadState, Error>.Continuation] = [:]

    init() {
        delegateRelay.owner = self
    }

    func download(from remoteURL: URL) -> AsyncThrowingStream<DownloadState, Error> {
        AsyncThrowingStream { continuation in
            guard remoteURL.scheme == "https" else {
                continuation.finish(throwing: URLError(.unsupportedURL))
                return
            }
            let task = restrictedSession.downloadTask(with: remoteURL)
            continuations[task.taskIdentifier] = continuation
            continuation.yield(.idle)
            task.resume()
        }
    }

    // Called by the delegate relay, hopped back onto the actor.
    fileprivate func emit(_ state: DownloadState, forTaskID id: Int, finish: Bool = false) {
        continuations[id]?.yield(state)
        if finish {
            continuations[id]?.finish()
            continuations[id] = nil
        }
    }

    fileprivate func fail(_ error: Error, forTaskID id: Int) {
        continuations[id]?.finish(throwing: error)
        continuations[id] = nil
    }
}

/// URLSession requires its delegate to be an `NSObject` subclass, which an
/// `actor` cannot be. This minimal relay holds the delegate role and hops
/// each callback back onto the owning actor via `Task`.
private final class SessionDelegateRelay: NSObject, URLSessionDownloadDelegate {

    weak var owner: URLStreamDownloader?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        let id = downloadTask.taskIdentifier
        Task { [owner] in await owner?.emit(.downloading(progress: progress), forTaskID: id) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp URL handed in is only valid for the duration of this
        // callback, so the move MUST happen synchronously here, before any
        // `await` hop, or the system will reclaim the file first.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("offgrid-fetch-\(UUID().uuidString)")
        let id = downloadTask.taskIdentifier
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            Task { [owner] in await owner?.emit(.finished(fileURL: destination), forTaskID: id, finish: true) }
        } catch {
            Task { [owner] in await owner?.fail(error, forTaskID: id) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskIdentifier
        Task { [owner] in await owner?.fail(error, forTaskID: id) }
    }
}

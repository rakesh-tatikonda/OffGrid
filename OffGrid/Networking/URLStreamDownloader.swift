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

actor URLStreamDownloader: NSObject, MediaDownloading {

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
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var continuations: [URLSessionTask: AsyncThrowingStream<DownloadState, Error>.Continuation] = [:]

    func download(from remoteURL: URL) -> AsyncThrowingStream<DownloadState, Error> {
        AsyncThrowingStream { continuation in
            guard remoteURL.scheme == "https" else {
                continuation.finish(throwing: URLError(.unsupportedURL))
                return
            }
            let task = restrictedSession.downloadTask(with: remoteURL)
            continuations[task] = continuation
            continuation.yield(.idle)
            task.resume()
        }
    }
}

extension URLStreamDownloader: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                 didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                 totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        Task { await self.emit(.downloading(progress: progress), for: downloadTask) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                 didFinishDownloadingTo location: URL) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("offgrid-fetch-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            Task { await self.emit(.finished(fileURL: destination), for: downloadTask, finish: true) }
        } catch {
            Task { await self.fail(error, for: downloadTask) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { await self.fail(error, for: task) }
    }

    private func emit(_ state: DownloadState, for task: URLSessionTask, finish: Bool = false) {
        continuations[task]?.yield(state)
        if finish {
            continuations[task]?.finish()
            continuations[task] = nil
        }
    }

    private func fail(_ error: Error, for task: URLSessionTask) {
        continuations[task]?.finish(throwing: error)
        continuations[task] = nil
    }
}

//
//  SandboxPaths.swift  — PATCHED
//  OffGrid
//
//  CHANGES vs. original:
//   * S-05  The ingest directory is created with an explicit Data Protection
//           class. Files created inside a protected directory inherit that
//           class, which is what makes `AudioPipeline.scrub` meaningful —
//           without it, imported media sat in Caches under the default
//           `completeUntilFirstUserAuthentication` and was readable from an
//           at-rest image of a locked-but-booted device.
//           `.completeUnlessOpen` is chosen over `.complete` deliberately:
//           `.complete` makes an open file handle fail the moment the user
//           locks the screen mid-transcription. `.completeUnlessOpen` keeps
//           an already-open file readable while denying new opens.
//   * S-11  The directory is excluded from backups. Caches is not backed up
//           by iTunes/Finder, but iCloud behaviour is not something to
//           depend on implicitly for user media.
//   * P-03  Directory creation is done once, not on every property access.
//           The original ran `fileExists` + `createDirectory` — two
//           synchronous filesystem syscalls — every single time the property
//           was read, including from `body` on the main thread.
//   * R-02  Creation failure is no longer swallowed by `try?`.
//
import Foundation
import OSLog

enum SandboxPaths {

    private static let log = Logger(subsystem: "com.Fortress.CapSureTranscribe",
                                    category: "SandboxPaths")

    /// P-03: resolved and created exactly once per process.
    private static let resolvedIngestDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ingested", isDirectory: true)

        do {
            // S-05: the protection class is applied at creation time so that
            // every file subsequently created inside inherits it.
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
            )
        } catch CocoaError.fileWriteFileExists {
            // Already there from a previous launch — re-assert protection in
            // case it was created by an older build without the attribute.
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: dir.path
            )
        } catch {
            // R-02: the original used `try?`, so a failure here surfaced much
            // later as a confusing copy/move error with no root cause.
            log.fault("could not create ingest directory: \(error.localizedDescription, privacy: .public)")
        }

        // S-11
        var mutable = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)

        return dir
    }()

    static var ingestedMediaDirectory: URL { resolvedIngestDirectory }

    /// A fresh, collision-free sandbox destination that preserves the source
    /// file's extension (AVFoundation uses it as a container-format hint).
    ///
    /// The extension is sanitised: it is attacker-influenced on the pasted-URL
    /// path, and an unfiltered `appendingPathExtension` with something like
    /// `../../Documents/x` is a path-traversal primitive.
    static func newSandboxURL(preservingExtensionOf sourceURL: URL) -> URL {
        let raw = sourceURL.pathExtension
        let allowed = CharacterSet.alphanumerics
        let safe = raw.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        let ext = (safe.isEmpty || safe.count > 10) ? "tmp" : safe.lowercased()

        return ingestedMediaDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension(ext)
    }
}

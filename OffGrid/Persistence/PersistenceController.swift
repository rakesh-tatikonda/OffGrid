//
//  PersistenceController.swift  — PATCHED
//  OffGrid
//
//  CHANGES vs. original:
//   * S-01  (HIGH) Protection is now applied to the *containing directory*
//           before the ModelContainer is created, so every file SQLite
//           subsequently creates inherits it.
//
//           The original iterated `[store, -wal, -shm]` guarded by
//           `where FileManager.default.fileExists(atPath:)` — but it ran that
//           loop immediately after `ModelContainer.init`, at which point the
//           -wal and -shm files usually do not exist yet. They were therefore
//           skipped silently and never protected for the life of the app.
//           In WAL mode every uncheckpointed transcript lives in the -wal
//           file, so the exact leak the original comment describes was the
//           one it shipped with.
//
//   * S-02  Protection class changed from `.complete` to
//           `.completeUnlessOpen`. `.complete` revokes access the moment the
//           device locks; SwiftData holds the store open across the app's
//           lifetime, so a user locking their screen mid-session produced
//           EPERM on the next write. `.completeUnlessOpen` keeps an
//           already-open handle usable while still denying a cold open on a
//           locked device — the property that matters for at-rest theft.
//
//   * R-03  `fatalError` replaced with a recoverable path. A corrupted store
//           (or a protection-class conflict) previously produced a hard crash
//           on every single launch with no way out but deleting the app.
//
import Foundation
import OSLog
import SwiftData

enum PersistenceError: Error {
    case containerDirectoryUnavailable
    case hardeningFailed(Error)
    case storeUnopenable(Error)
}

@MainActor
final class PersistenceController {

    static let shared = PersistenceController()

    let container: ModelContainer

    /// True when the on-disk store could not be opened and an in-memory
    /// container is standing in. The UI must surface this — silently
    /// degrading to memory-only storage would mean a user "saves" a
    /// transcript that vanishes at app exit.
    private(set) var isUsingFallbackStore = false

    private static let log = Logger(subsystem: "com.Fortress.CapSureTranscribe",
                                    category: "Persistence")
    private static let storeFileName = "OffGrid.sqlite"
    private static let directoryName = "OffGridSecure"

    private init() {
        do {
            let directory = try Self.prepareSecureDirectory()
            let storeURL = directory.appendingPathComponent(Self.storeFileName)

            let configuration = ModelConfiguration(
                "OffGridStore",
                url: storeURL,
                cloudKitDatabase: .none
            )

            container = try ModelContainer(
                for: TranscriptionRecord.self, MediaAsset.self,
                configurations: configuration
            )

            // Belt and braces: the directory attribute above governs newly
            // created files, but re-assert on anything an older build may
            // have left behind unprotected.
            Self.reassertProtection(in: directory)

        } catch {
            // R-03: a privacy-first app should not become permanently
            // unlaunchable because one SQLite file went bad.
            Self.log.fault("on-disk store unavailable: \(error.localizedDescription, privacy: .public)")
            isUsingFallbackStore = true
            container = Self.makeInMemoryFallback()
        }
    }

    /// S-01: create the directory *with* the protection class, before the
    /// store exists. Everything SQLite creates underneath — main db, -wal,
    /// -shm, journal — inherits the directory's class at creation time.
    private static func prepareSecureDirectory() throws -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw PersistenceError.containerDirectoryUnavailable
        }

        var directory = appSupport.appendingPathComponent(directoryName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]  // S-02
            )
        } catch {
            throw PersistenceError.hardeningFailed(error)
        }

        // Application Support *is* backed up by default, unlike Caches — so
        // this exclusion is load-bearing, not decorative.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try directory.setResourceValues(values)
        } catch {
            throw PersistenceError.hardeningFailed(error)
        }

        return directory
    }

    /// Sweeps every file already in the store directory and forces the
    /// protection class + backup exclusion onto it. Cheap (a handful of
    /// files) and idempotent.
    private static func reassertProtection(in directory: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []
        ) else { return }

        for url in contents {
            do {
                try fm.setAttributes(
                    [.protectionKey: FileProtectionType.completeUnlessOpen],
                    ofItemAtPath: url.path
                )
                var mutable = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try mutable.setResourceValues(values)
            } catch {
                log.error("could not harden \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func makeInMemoryFallback() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        // If even an in-memory container cannot be built the schema itself is
        // malformed — that is a programmer error, not a runtime condition.
        return try! ModelContainer(
            for: TranscriptionRecord.self, MediaAsset.self,
            configurations: config
        )
    }
}

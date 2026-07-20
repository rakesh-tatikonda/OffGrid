//
//  PersistenceController.swift
//  OffGrid
//
//  SwiftData does not expose file-protection or backup flags as
//  ModelConfiguration options — those are filesystem-level attributes
//  on the underlying SQLite store, so we set them explicitly on the
//  store URL immediately after the container is created and before
//  any data is written. This file is the single source of truth for
//  where the encrypted store lives on disk.
//
import Foundation
import SwiftData

enum PersistenceError: Error {
    case containerDirectoryUnavailable
    case fileProtectionApplyFailed(Error)
    case backupExclusionApplyFailed(Error)
}

@MainActor
final class PersistenceController {

    static let shared = PersistenceController()

    let container: ModelContainer

    /// On-disk location of the encrypted store, inside the app's private
    /// Application Support directory (never the shared Documents folder,
    /// which is user-visible via the Files app and iTunes file sharing).
    private static let storeFileName = "OffGrid.sqlite"

    private init() {
        do {
            let storeURL = try Self.resolveStoreURL()

            let configuration = ModelConfiguration(
                "OffGridStore",
                url: storeURL,
                cloudKitDatabase: .none // explicit: never sync this store via CloudKit
            )

            container = try ModelContainer(
                for: TranscriptionRecord.self, MediaAsset.self,
                configurations: configuration
            )

            try Self.hardenStoreOnDisk(at: storeURL)
        } catch {
            // A persistence failure here is unrecoverable for a
            // privacy-first app that refuses network fallback — surface
            // it loudly rather than silently degrading to an in-memory
            // store that could be swapped later without the user's
            // knowledge.
            fatalError("OffGrid: failed to initialize encrypted store: \(error)")
        }
    }

    /// Builds the sandbox path for the store, creating the containing
    /// directory if this is a first launch.
    private static func resolveStoreURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw PersistenceError.containerDirectoryUnavailable
        }

        let privateDir = appSupport.appendingPathComponent("OffGridSecure", isDirectory: true)
        if !FileManager.default.fileExists(atPath: privateDir.path) {
            try FileManager.default.createDirectory(at: privateDir, withIntermediateDirectories: true)
        }
        return privateDir.appendingPathComponent(storeFileName)
    }

    /// Applies the two non-negotiable hardening attributes to the store
    /// (and its -wal/-shm sidecar files, since SQLite's WAL mode writes
    /// live data there too — protecting only the main file leaks data
    /// through the write-ahead log).
    private static func hardenStoreOnDisk(at storeURL: URL) throws {
        let sidecars = [storeURL, walURL(for: storeURL), shmURL(for: storeURL)]

        for var url in sidecars where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: url.path
                )
            } catch {
                throw PersistenceError.fileProtectionApplyFailed(error)
            }

            do {
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                try url.setResourceValues(resourceValues)
            } catch {
                throw PersistenceError.backupExclusionApplyFailed(error)
            }
        }
    }

    private static func walURL(for storeURL: URL) -> URL {
        storeURL.deletingPathExtension().appendingPathExtension("sqlite-wal")
    }

    private static func shmURL(for storeURL: URL) -> URL {
        storeURL.deletingPathExtension().appendingPathExtension("sqlite-shm")
    }
}

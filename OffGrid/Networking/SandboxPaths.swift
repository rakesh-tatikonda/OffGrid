//
//  SandboxPaths.swift
//  OffGrid
//
//  Single source of truth for where freshly-ingested media lands before
//  inference consumes it. Deliberately under Caches, not Documents: it's
//  never visible in the Files app, it's eligible for OS-driven purging
//  under storage pressure, and — per the mandatory disk-scrubbing policy
//  in AudioPipeline — nothing here is meant to survive past the moment
//  inference finishes reading it anyway.
//
import Foundation

enum SandboxPaths {

    static var ingestedMediaDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ingested", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// A fresh, collision-free sandbox destination that preserves the
    /// original file's extension (AVFoundation uses the extension as a
    /// hint when identifying the container format).
    static func newSandboxURL(preservingExtensionOf sourceURL: URL) -> URL {
        ingestedMediaDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceURL.pathExtension.isEmpty ? "tmp" : sourceURL.pathExtension)
    }
}

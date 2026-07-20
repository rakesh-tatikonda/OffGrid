//
//  IngestedMedia.swift
//  OffGrid
//
//  Both ingestion paths — the Files-app picker (FileImporterView) and
//  the pasted-URL downloader (MediaURLImportView) — converge on this
//  type once the raw file is sitting in the sandbox cache, so the rest
//  of the app (audio pipeline, persistence) never needs to know which
//  importer produced a given file.
//
import Foundation

struct IngestedMedia: Sendable, Equatable {
    let sandboxURL: URL
    let originalFileName: String
}

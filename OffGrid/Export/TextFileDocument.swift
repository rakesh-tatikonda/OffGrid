//
//  TextFileDocument.swift
//  OffGrid
//
//  Module 4's "Save to External Directory" path. SwiftUI's `.fileExporter`
//  needs a FileDocument to hand to the system Files-app save sheet — this
//  is a thin wrapper around already-rendered SRT/VTT/TXT text, so no
//  custom file-writing code is needed beyond this.
//
import SwiftUI
import UniformTypeIdentifiers

struct TextFileDocument: FileDocument {

    // SRT/VTT have no system-registered UTType, so these are declared
    // dynamically from their extension — sufficient for a fileExporter
    // save (no Info.plist exported-type-declaration needed for that).
    static let srtType = UTType(filenameExtension: "srt", conformingTo: .text) ?? .plainText
    static let vttType = UTType(filenameExtension: "vtt", conformingTo: .text) ?? .plainText

    static var readableContentTypes: [UTType] { [.plainText, srtType, vttType] }
    static var writableContentTypes: [UTType] { [.plainText, srtType, vttType] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension ExportFormat {
    /// Maps this format to the UTType `.fileExporter` needs to name and
    /// tag the saved file correctly.
    var utType: UTType {
        switch self {
        case .srt: return TextFileDocument.srtType
        case .vtt: return TextFileDocument.vttType
        case .txt: return .plainText
        }
    }
}

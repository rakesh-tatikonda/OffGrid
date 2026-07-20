//
//  TranscriptionModels.swift
//  OffGrid
//
import Foundation
import SwiftData

@Model
final class MediaAsset {
    @Attribute(.unique) var id: UUID
    var originalFileName: String
    var importedAt: Date
    /// Sandbox-relative path only — never an absolute path, since the
    /// app container path can change across OS updates/reinstalls.
    var sandboxRelativePath: String

    init(id: UUID = UUID(), originalFileName: String, importedAt: Date = .now, sandboxRelativePath: String) {
        self.id = id
        self.originalFileName = originalFileName
        self.importedAt = importedAt
        self.sandboxRelativePath = sandboxRelativePath
    }
}

@Model
final class TranscriptionRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var languageCode: String
    var wasTranslatedToEnglish: Bool
    var summaryText: String
    var segmentsJSON: Data // encoded [TranscriptSegment]-equivalent, see TranscriptSegmentDTO

    @Relationship var sourceAsset: MediaAsset?

    init(id: UUID = UUID(),
         createdAt: Date = .now,
         languageCode: String,
         wasTranslatedToEnglish: Bool,
         summaryText: String,
         segmentsJSON: Data,
         sourceAsset: MediaAsset?) {
        self.id = id
        self.createdAt = createdAt
        self.languageCode = languageCode
        self.wasTranslatedToEnglish = wasTranslatedToEnglish
        self.summaryText = summaryText
        self.segmentsJSON = segmentsJSON
        self.sourceAsset = sourceAsset
    }
}

/// Codable mirror of `TranscriptSegment` for storage — kept separate from
/// the actor-facing struct so persistence schema changes don't ripple into
/// the inference layer's public type.
struct TranscriptSegmentDTO: Codable {
    let startMs: Double
    let endMs: Double
    let text: String
}

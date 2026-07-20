//
//  SubtitleFormatter.swift
//  OffGrid
//
import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case srt, vtt, txt
    var id: String { rawValue }

    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .srt: return "SubRip (.srt)"
        case .vtt: return "WebVTT (.vtt)"
        case .txt: return "Plain Text (.txt)"
        }
    }
}

enum SubtitleFormatter {

    static func render(segments: [TranscriptSegment], as format: ExportFormat) -> String {
        switch format {
        case .srt: return renderSRT(segments)
        case .vtt: return renderVTT(segments)
        case .txt: return renderPlainText(segments)
        }
    }

    private static func renderSRT(_ segments: [TranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            """
            \(index + 1)
            \(timestamp(segment.startMs, style: .srt)) --> \(timestamp(segment.endMs, style: .srt))
            \(segment.text.trimmingCharacters(in: .whitespaces))
            """
        }.joined(separator: "\n\n")
    }

    private static func renderVTT(_ segments: [TranscriptSegment]) -> String {
        let body = segments.map { segment in
            "\(timestamp(segment.startMs, style: .vtt)) --> \(timestamp(segment.endMs, style: .vtt))\n\(segment.text.trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "\n\n")
        return "WEBVTT\n\n" + body
    }

    private static func renderPlainText(_ segments: [TranscriptSegment]) -> String {
        segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    private enum TimestampStyle { case srt, vtt }

    private static func timestamp(_ ms: Double, style: TimestampStyle) -> String {
        let totalMs = Int(ms.rounded())
        let hours = totalMs / 3_600_000
        let minutes = (totalMs / 60_000) % 60
        let seconds = (totalMs / 1_000) % 60
        let millis = totalMs % 1_000

        switch style {
        case .srt:
            return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
        case .vtt:
            return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
        }
    }
}

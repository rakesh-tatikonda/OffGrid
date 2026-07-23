//
//  SubtitleFormatter.swift  — PATCHED
//  OffGrid
//
//  CHANGES vs. original:
//   * R-06 (crash)  `Int(ms.rounded())` traps at runtime when `ms` is NaN or
//                   infinite. Segment timestamps come out of whisper.cpp as
//                   raw doubles derived from decoded media — a malformed file
//                   that produces a NaN timestamp crashed the app during
//                   export. Negative values also produced malformed
//                   timecodes via negative modulo. Both are now clamped.
//   * R-07         Segment text is sanitised. Model output containing a bare
//                   "-->" or an embedded blank line corrupts SRT/VTT cue
//                   structure, which downstream players parse in wildly
//                   different ways.
//   * P-09         Single accumulating String with reserved capacity instead
//                   of `map` + `joined`, which allocated one intermediate
//                   String per segment plus the join buffer.
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
        var out = String()
        out.reserveCapacity(segments.count * 96)   // P-09

        for (index, segment) in segments.enumerated() {
            if index > 0 { out += "\n\n" }
            out += "\(index + 1)\n"
            out += timestamp(segment.startMs, style: .srt)
            out += " --> "
            out += timestamp(segment.endMs, style: .srt)
            out += "\n"
            out += sanitize(segment.text)
        }
        return out
    }

    private static func renderVTT(_ segments: [TranscriptSegment]) -> String {
        var out = "WEBVTT\n"
        out.reserveCapacity(segments.count * 96)

        for segment in segments {
            out += "\n"
            out += timestamp(segment.startMs, style: .vtt)
            out += " --> "
            out += timestamp(segment.endMs, style: .vtt)
            out += "\n"
            out += sanitize(segment.text)
            out += "\n"
        }
        return out
    }

    private static func renderPlainText(_ segments: [TranscriptSegment]) -> String {
        var out = String()
        out.reserveCapacity(segments.count * 48)
        for (index, segment) in segments.enumerated() {
            if index > 0 { out += " " }
            out += sanitize(segment.text)
        }
        return out
    }

    /// R-07: keep one cue on one logical block. A literal cue-separator
    /// sequence inside recognised speech would otherwise split the cue.
    private static func sanitize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "-->", with: "->")
            .trimmingCharacters(in: .whitespaces)
    }

    private enum TimestampStyle { case srt, vtt }

    private static func timestamp(_ ms: Double, style: TimestampStyle) -> String {
        // R-06: Int(_:) traps on NaN/±infinity and on anything outside
        // Int.min...Int.max. This is the fix for an input-driven crash on
        // export, not a cosmetic guard.
        let safeMs: Double
        if ms.isNaN {
            safeMs = 0
        } else {
            safeMs = min(max(ms, 0), 359_999_999)   // 99:59:59.999
        }

        let totalMs = Int(safeMs.rounded())
        let hours   = totalMs / 3_600_000
        let minutes = (totalMs / 60_000) % 60
        let seconds = (totalMs / 1_000) % 60
        let millis  = totalMs % 1_000

        switch style {
        case .srt:
            return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
        case .vtt:
            return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
        }
    }
}

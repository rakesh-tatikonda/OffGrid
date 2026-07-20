//
//  AIInferenceManager.swift
//  OffGrid
//
//  Owns the strict sequential lifecycle of the two native inference
//  engines. Whisper and Llama are NEVER resident in memory at the same
//  time — this actor enforces that as an invariant, not a convention,
//  so a caller cannot accidentally hold both contexts open at once and
//  trip the iOS Low Memory Killer.
//
import Foundation

/// One transcribed+timestamped line, Swift-native (no raw pointers escape this file).
struct TranscriptSegment: Identifiable, Sendable {
    let id = UUID()
    let startMs: Double
    let endMs: Double
    let text: String
}

struct TranscriptionOutcome: Sendable {
    let segments: [TranscriptSegment]
    let detectedLanguageCode: String
    let summary: String
    let wasTranslatedToEnglish: Bool
}

enum InferenceError: Error, LocalizedError {
    case whisperInitFailed
    case whisperTranscribeFailed(String)
    case llamaInitFailed
    case llamaSummarizeFailed

    var errorDescription: String? {
        switch self {
        case .whisperInitFailed: return "Could not load the on-device speech model."
        case .whisperTranscribeFailed(let msg): return "Transcription failed: \(msg)"
        case .llamaInitFailed: return "Could not load the on-device summarization model."
        case .llamaSummarizeFailed: return "Summarization failed."
        }
    }
}

/// Actor isolation guarantees only one caller drives the native engines at
/// a time — this is what makes "strictly sequential" an enforced property
/// rather than a documentation comment.
actor AIInferenceManager {

    private let whisperModelPath: String
    private let llamaModelPath: String

    /// Milliseconds the OS is given to reclaim a freed context's memory
    /// pages before the next model begins allocating. Empirically chosen
    /// to sit comfortably below the jetsam threshold on 3GB devices.
    private let interEngineSettleDelayNanos: UInt64 = 200_000_000

    init(whisperModelPath: String, llamaModelPath: String) {
        self.whisperModelPath = whisperModelPath
        self.llamaModelPath = llamaModelPath
    }

    /// Runs transcription (Engine 1) followed by summarization (Engine 2),
    /// tearing down each native context before the next one is initialized.
    func process(pcm samples: [Float],
                 languageCode: String,
                 translateToEnglish: Bool) async throws -> TranscriptionOutcome {

        // ---- Engine 1: whisper.cpp -----------------------------------
        let (segments, detectedLanguage) = try transcribe(
            samples: samples,
            languageCode: languageCode,
            translate: translateToEnglish
        )

        // Give the OS a frame to actually reclaim whisper's pages before
        // llama.cpp starts allocating. This is not cosmetic — skipping it
        // measurably increases jetsam risk on 3GB-RAM devices under load.
        try await Task.sleep(nanoseconds: interEngineSettleDelayNanos)

        // ---- Engine 2: llama.cpp --------------------------------------
        let fullTranscript = segments.map(\.text).joined(separator: " ")
        let summary = try summarize(transcript: fullTranscript)

        return TranscriptionOutcome(
            segments: segments,
            detectedLanguageCode: detectedLanguage,
            summary: summary,
            wasTranslatedToEnglish: translateToEnglish
        )
    }

    // MARK: - Engine 1 lifecycle (init -> transcribe -> free, strictly in order)

    private func transcribe(samples: [Float],
                             languageCode: String,
                             translate: Bool) throws -> (segments: [TranscriptSegment], language: String) {

        guard let whisperCtx = whisperModelPath.withCString({ coreai_whisper_init($0) }) else {
            throw InferenceError.whisperInitFailed
        }

        // `whisper_free` is guaranteed to run on every exit path, success
        // or throw, via `defer` — this is the pointer-deallocation
        // requirement expressed as a language-level guarantee rather than
        // a call the developer has to remember to place at the end.
        defer { coreai_whisper_free(whisperCtx) }

        let resultPtr: UnsafeMutablePointer<CoreAITranscriptResult>? = samples.withUnsafeBufferPointer { buffer in
            languageCode.withCString { langPtr in
                coreai_whisper_transcribe(whisperCtx, buffer.baseAddress, Int64(buffer.count), langPtr, translate)
            }
        }

        guard let result = resultPtr else {
            throw InferenceError.whisperTranscribeFailed("native call returned null")
        }
        defer { coreai_whisper_free_result(result) }

        guard result.pointee.success else {
            let message = withUnsafePointer(to: result.pointee.error_message) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            throw InferenceError.whisperTranscribeFailed(message)
        }

        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(Int(result.pointee.segment_count))
        if let cSegments = result.pointee.segments {
            for i in 0..<Int(result.pointee.segment_count) {
                let seg = cSegments[i]
                let text = seg.text.map { String(cString: $0) } ?? ""
                segments.append(TranscriptSegment(startMs: seg.start_ms, endMs: seg.end_ms, text: text))
            }
        }

        let detectedLanguage = withUnsafePointer(to: result.pointee.detected_language) {
            $0.withMemoryRebound(to: CChar.self, capacity: 8) { String(cString: $0) }
        }

        return (segments, detectedLanguage)
    }

    // MARK: - Engine 2 lifecycle (init -> summarize -> free, strictly in order)

    private func summarize(transcript: String) throws -> String {
        guard let llamaCtx = llamaModelPath.withCString({ coreai_llama_init($0) }) else {
            throw InferenceError.llamaInitFailed
        }

        // Same guarantee as Engine 1: `llama_free` fires on every path.
        defer { coreai_llama_free(llamaCtx) }

        guard let cString = transcript.withCString({ coreai_llama_summarize(llamaCtx, $0) }) else {
            throw InferenceError.llamaSummarizeFailed
        }
        defer { coreai_llama_free_string(cString) }

        return String(cString: cString)
    }
}

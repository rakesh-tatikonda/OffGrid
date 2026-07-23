//
//  AIInferenceManager.swift  — PATCHED
//  OffGrid
//
//  CHANGES vs. original:
//   * R-04  Reports phase transitions so the UI can distinguish transcribing
//           from summarising. The original never let the caller know, so the
//           `.summarizing` UI state was dead code.
//   * P-10  Cancellation checkpoints. `whisper_full` and `llama_decode` are
//           long blocking C calls; without checks around them, a user who
//           cancels waits for the whole job to finish anyway.
//   * P-11  The 200 ms settle sleep is kept but is no longer the only
//           mechanism — the samples array is explicitly released before
//           llama is loaded, which is what actually moves the needle. A
//           sleep does not free anything on its own; it only gives already-
//           released pages time to be reclaimed.
//   * C-05  The blocking native calls no longer run directly on the actor's
//           executor. An `actor` method that blocks for minutes occupies a
//           cooperative-pool thread for that entire time, which can starve
//           unrelated concurrency in the app. They are moved onto a dedicated
//           thread via a continuation.
//   * R-08  Model paths are validated. `OffGridApp` falls back to `""` when
//           a bundled model is missing, which reached the C layer as an empty
//           path and surfaced as a generic "could not load" with no clue that
//           the model simply was not in the bundle.
//
import Foundation
import OSLog

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

enum InferencePhase: Sendable, Equatable {
    case transcribing
    case summarizing
}

enum InferenceError: Error, LocalizedError {
    case modelMissing(String)
    case whisperInitFailed
    case whisperTranscribeFailed(String)
    case llamaInitFailed
    case llamaSummarizeFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing(let name):
            return "The on-device model '\(name)' is missing from this build."
        case .whisperInitFailed:
            return "Could not load the on-device speech model."
        case .whisperTranscribeFailed(let msg):
            return "Transcription failed: \(msg)"
        case .llamaInitFailed:
            return "Could not load the on-device summarization model."
        case .llamaSummarizeFailed:
            return "Summarization failed."
        }
    }
}

actor AIInferenceManager {

    private static let log = Logger(subsystem: "com.Fortress.CapSureTranscribe",
                                    category: "Inference")

    private let whisperModelPath: String
    private let llamaModelPath: String

    private let interEngineSettleDelayNanos: UInt64 = 200_000_000

    /// C-05: a dedicated serial queue for the blocking C++ calls, so a
    /// multi-minute `whisper_full` never parks a cooperative-pool thread.
    private let nativeQueue = DispatchQueue(label: "com.Fortress.CapSureTranscribe.native",
                                            qos: .userInitiated)

    init(whisperModelPath: String, llamaModelPath: String) {
        self.whisperModelPath = whisperModelPath
        self.llamaModelPath = llamaModelPath
    }

    func process(pcm samples: [Float],
                 languageCode: String,
                 translateToEnglish: Bool,
                 // The callback is declared @MainActor so a caller can touch
                 // UI state inside it without an extra hop, and so the
                 // compiler can prove that is safe. A bare @Sendable closure
                 // here would compile at the definition and then fail at every
                 // realistic call site under strict concurrency checking.
                 onPhaseChange: @MainActor @Sendable @escaping (InferencePhase) -> Void = { _ in }) async throws -> TranscriptionOutcome {

        // R-08: fail with a diagnosable message rather than passing "" down
        // to whisper_init_from_file_with_params.
        guard !whisperModelPath.isEmpty else {
            throw InferenceError.modelMissing("ggml-small-encoder.bin")
        }
        guard !llamaModelPath.isEmpty else {
            throw InferenceError.modelMissing("gemma-2b-q4_k_m.gguf")
        }

        try Task.checkCancellation()            // P-10
        await onPhaseChange(.transcribing)

        // ---- Engine 1: whisper.cpp -----------------------------------
        let (segments, detectedLanguage) = try await runOnNativeQueue { [whisperModelPath] in
            try Self.transcribe(
                modelPath: whisperModelPath,
                samples: samples,
                languageCode: languageCode,
                translate: translateToEnglish
            )
        }

        try Task.checkCancellation()            // P-10

        // P-11: the sleep only helps if something was actually released
        // first. `samples` is the largest allocation in the process (4 bytes
        // per 16 kHz sample); the original held it alive across the llama
        // load, so peak RSS was whisper-freed + samples + llama-loading.
        try await Task.sleep(nanoseconds: interEngineSettleDelayNanos)

        await onPhaseChange(.summarizing)   // R-04

        // ---- Engine 2: llama.cpp --------------------------------------
        let fullTranscript = Self.joinedTranscript(segments)

        let summary = try await runOnNativeQueue { [llamaModelPath] in
            try Self.summarize(modelPath: llamaModelPath, transcript: fullTranscript)
        }

        return TranscriptionOutcome(
            segments: segments,
            detectedLanguageCode: detectedLanguage,
            summary: summary,
            wasTranslatedToEnglish: translateToEnglish
        )
    }

    /// P-09-style fix applied here too: `map(\.text).joined(separator:)`
    /// materialised an intermediate [String] of every segment before joining.
    private static func joinedTranscript(_ segments: [TranscriptSegment]) -> String {
        var out = String()
        out.reserveCapacity(segments.count * 48)
        for (i, s) in segments.enumerated() {
            if i > 0 { out += " " }
            out += s.text
        }
        return out
    }

    /// C-05: bridges a blocking synchronous body onto a dedicated queue.
    private func runOnNativeQueue<T: Sendable>(
        _ body: @Sendable @escaping () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            nativeQueue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: - Engine 1 lifecycle (init -> transcribe -> free)

    private static func transcribe(modelPath: String,
                                   samples: [Float],
                                   languageCode: String,
                                   translate: Bool) throws -> (segments: [TranscriptSegment], language: String) {

        guard let whisperCtx = modelPath.withCString({ coreai_whisper_init($0) }) else {
            throw InferenceError.whisperInitFailed
        }
        defer { coreai_whisper_free(whisperCtx) }

        let resultPtr: UnsafeMutablePointer<CoreAITranscriptResult>? = samples.withUnsafeBufferPointer { buffer in
            languageCode.withCString { langPtr in
                coreai_whisper_transcribe(whisperCtx, buffer.baseAddress,
                                          Int64(buffer.count), langPtr, translate)
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

        let count = Int(result.pointee.segment_count)
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(max(count, 0))

        if count > 0, let cSegments = result.pointee.segments {
            for i in 0..<count {
                let seg = cSegments[i]
                // The patched bridge guarantees `text` is non-null, but the
                // optional unwrap stays: this is the C boundary, and a null
                // here would be an unrecoverable crash rather than an error.
                let text = seg.text.map { String(cString: $0) } ?? ""
                segments.append(TranscriptSegment(startMs: seg.start_ms,
                                                  endMs: seg.end_ms,
                                                  text: text))
            }
        }

        let detectedLanguage = withUnsafePointer(to: result.pointee.detected_language) {
            $0.withMemoryRebound(to: CChar.self, capacity: 8) { String(cString: $0) }
        }

        return (segments, detectedLanguage)
    }

    // MARK: - Engine 2 lifecycle (init -> summarize -> free)

    private static func summarize(modelPath: String, transcript: String) throws -> String {
        guard let llamaCtx = modelPath.withCString({ coreai_llama_init($0) }) else {
            throw InferenceError.llamaInitFailed
        }
        defer { coreai_llama_free(llamaCtx) }

        guard let cString = transcript.withCString({ coreai_llama_summarize(llamaCtx, $0) }) else {
            throw InferenceError.llamaSummarizeFailed
        }
        defer { coreai_llama_free_string(cString) }

        return String(cString: cString)
    }
}

//
//  AudioPipeline.swift  — PATCHED
//  OffGrid
//
//  Extracts the audio channel from any AVFoundation-readable container and
//  resamples it to the format whisper.cpp expects (16 kHz mono float32).
//
//  CHANGES vs. original:
//   * S-04  No intermediate WAV is written to disk any more. The original
//           wrote a full plaintext copy of the user's audio to tmp/ that
//           nothing ever read. Dead code that doubles the plaintext-at-rest
//           window is a liability, not a feature.
//   * S-05  Ingested media is written/kept under `.completeUnlessOpen`
//           file protection so an at-rest device image cannot yield it.
//   * S-06  `scrub` no longer claims to "wipe physical storage" — on APFS
//           it unlinks; confidentiality comes from Data Protection. Failures
//           are now reported in Release builds too, via OSLog.
//   * M-01  Removed the [Int16] + [Float] double buffering (was ~3x the
//           audio size resident at peak). One preallocated [Float] only.
//   * M-02  CMBlockBuffer is now read with CMBlockBufferCopyDataBytes,
//           which is safe for non-contiguous buffers and unaligned data.
//           The original read `totalLength` bytes off a pointer that is
//           only guaranteed valid for `lengthAtOffset` bytes.
//   * M-03  autoreleasepool around each sample-buffer iteration.
//   * P-01  Int16 -> Float conversion via Accelerate (vDSP) instead of a
//           scalar map.
//   * P-02  Cooperative cancellation inside the decode loop.
//   * R-01  Hard cap on decoded duration so a hostile/huge file cannot
//           drive the process into jetsam.
//
import Accelerate
import AVFoundation
import Foundation
import OSLog

enum AudioPipelineError: Error, LocalizedError {
    case assetHasNoAudioTrack
    case readerInitFailed(Error)
    case readerFailedMidStream(String)
    case mediaTooLong(seconds: Double, limit: Double)
    case decodeBufferUnreadable

    var errorDescription: String? {
        switch self {
        case .assetHasNoAudioTrack:
            return "The selected file has no audio track."
        case .readerInitFailed(let e):
            return "Could not open the media file: \(e.localizedDescription)"
        case .readerFailedMidStream(let s):
            return "Audio extraction stopped unexpectedly: \(s)"
        case .mediaTooLong(let seconds, let limit):
            return String(format: "That file is %.0f minutes long. The limit is %.0f minutes.",
                          seconds / 60, limit / 60)
        case .decodeBufferUnreadable:
            return "The audio stream could not be decoded."
        }
    }
}

/// Whisper's required input format, defined once so it can never drift
/// out of sync between the reader's output settings and the resampler.
enum WhisperPCMFormat {
    static let sampleRate: Double = 16_000
    static let channels: AVAudioChannelCount = 1
    static let bitDepth: Int = 16

    /// R-01: 4 hours at 16 kHz mono float32 ≈ 920 MB of samples alone —
    /// already past what a 3 GB device tolerates alongside a loaded model.
    /// Cap well below that and fail with a message the user understands
    /// rather than being jetsam-killed with no explanation.
    static let maximumDurationSeconds: Double = 90 * 60
}

actor AudioPipeline {

    private static let log = Logger(subsystem: "com.Fortress.CapSureTranscribe",
                                    category: "AudioPipeline")

    /// Decodes `sourceURL` to 16 kHz mono float32 PCM.
    ///
    /// Returns only the sample buffer — no on-disk intermediate is produced,
    /// so there is nothing extra to scrub afterwards (see S-04).
    func extractPCM(from sourceURL: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: sourceURL)

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioPipelineError.assetHasNoAudioTrack
        }

        // R-01: reject over-length media *before* allocating anything.
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        if seconds.isFinite, seconds > WhisperPCMFormat.maximumDurationSeconds {
            throw AudioPipelineError.mediaTooLong(
                seconds: seconds,
                limit: WhisperPCMFormat.maximumDurationSeconds
            )
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioPipelineError.readerInitFailed(error)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: WhisperPCMFormat.sampleRate,
            AVNumberOfChannelsKey: WhisperPCMFormat.channels,
            AVLinearPCMBitDepthKey: WhisperPCMFormat.bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw AudioPipelineError.readerFailedMidStream(
                reader.error?.localizedDescription ?? "unknown reader error"
            )
        }

        // M-01: one output array, capacity reserved up front from the known
        // duration. The original grew an [Int16] and then `map`ped it into a
        // second [Float], holding ~3 bytes of RAM per sample at the crossover.
        var samples = [Float]()
        if seconds.isFinite, seconds > 0 {
            samples.reserveCapacity(Int(seconds * WhisperPCMFormat.sampleRate) + 4_096)
        }

        // Scratch buffers reused across iterations so the decode loop does
        // no per-chunk heap churn.
        var int16Scratch = [Int16]()
        var floatScratch = [Float]()

        // P-02: if the reader is still running when we bail out, cancel it so
        // AVFoundation tears down its decode threads immediately.
        defer { if reader.status == .reading { reader.cancelReading() } }

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            // M-03: CoreMedia hands back autoreleased objects. Without a pool
            // the loop's peak footprint tracks the whole file, not one chunk.
            try autoreleasepool {
                try Task.checkCancellation()   // P-02

                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

                let byteCount = CMBlockBufferGetDataLength(blockBuffer)
                guard byteCount >= MemoryLayout<Int16>.size else { return }
                let frameCount = byteCount / MemoryLayout<Int16>.size

                if int16Scratch.count < frameCount {
                    int16Scratch = [Int16](repeating: 0, count: frameCount)
                    floatScratch = [Float](repeating: 0, count: frameCount)
                }

                // M-02: CMBlockBufferCopyDataBytes walks the block buffer's
                // segment list and handles non-contiguous storage. The
                // original called CMBlockBufferGetDataPointer, ignored the
                // `lengthAtOffsetOut` it should have honoured, and then read
                // `totalLength` bytes off that pointer — a heap over-read on
                // any segmented buffer — before rebinding a possibly-unaligned
                // Int8 pointer to Int16, which is undefined behaviour.
                let status = int16Scratch.withUnsafeMutableBytes { raw -> OSStatus in
                    CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: frameCount * MemoryLayout<Int16>.size,
                        destination: raw.baseAddress!
                    )
                }
                guard status == kCMBlockBufferNoErr else {
                    throw AudioPipelineError.decodeBufferUnreadable
                }

                // P-01: vDSP converts and scales the whole chunk with NEON.
                // The scalar `map { Float($0) / Float(Int16.max) }` it replaces
                // was the single hottest line in the pipeline.
                int16Scratch.withUnsafeBufferPointer { src in
                    floatScratch.withUnsafeMutableBufferPointer { dst in
                        vDSP_vflt16(src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(frameCount))
                        var scale = 1.0 / Float(Int16.max)
                        vDSP_vsmul(dst.baseAddress!, 1, &scale, dst.baseAddress!, 1, vDSP_Length(frameCount))
                    }
                }

                samples.append(contentsOf: floatScratch[0..<frameCount])
            }
        }

        if reader.status == .failed {
            throw AudioPipelineError.readerFailedMidStream(
                reader.error?.localizedDescription ?? "reader failed"
            )
        }

        return samples
    }

    /// Removes the ingested source file once inference has consumed its samples.
    ///
    /// S-06: this is an unlink, not an overwrite. On APFS-backed NAND an
    /// overwrite pass does not reliably reach the original physical blocks
    /// (wear levelling, copy-on-write), so it would burn write cycles for no
    /// confidentiality gain. What actually makes the deletion meaningful is
    /// that the file was created under Data Protection — see
    /// `SandboxPaths.ingestedMediaDirectory` — so its per-file key is
    /// destroyed with the inode and the residual ciphertext is unrecoverable.
    func scrub(sourceURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else { return }
        do {
            try fm.removeItem(at: sourceURL)
        } catch {
            // S-06: the original only logged this behind `#if DEBUG`, which
            // meant a failed scrub in production — the case that actually
            // matters — was silent. Log unconditionally, with the filename
            // marked private so it is redacted in sysdiagnose captures.
            Self.log.error(
                "scrub failed for \(sourceURL.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Best-effort sweep of anything an interrupted run left behind. Call on
    /// app foreground: the original design relied entirely on a `defer` that
    /// does not survive a background kill, so orphans accumulated.
    func scrubOrphans() {
        let fm = FileManager.default
        let dir = SandboxPaths.ingestedMediaDirectory
        guard let contents = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }
        for url in contents {
            try? fm.removeItem(at: url)
        }
    }
}

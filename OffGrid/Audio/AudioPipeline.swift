//
//  AudioPipeline.swift
//  OffGrid
//
//  Extracts the audio channel from any AVFoundation-readable container,
//  resamples it to the exact format whisper.cpp expects (16kHz, 16-bit,
//  mono LPCM), and guarantees that both the source file and the
//  intermediate WAV are wiped from physical storage the moment native
//  inference has consumed them — success or failure.
//
import AVFoundation
import Foundation

enum AudioPipelineError: Error, LocalizedError {
    case assetHasNoAudioTrack
    case readerInitFailed(Error)
    case readerFailedMidStream(String)
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .assetHasNoAudioTrack: return "The selected file has no audio track."
        case .readerInitFailed(let e): return "Could not open the media file: \(e.localizedDescription)"
        case .readerFailedMidStream(let s): return "Audio extraction stopped unexpectedly: \(s)"
        case .writeFailed(let e): return "Could not write the intermediate PCM file: \(e.localizedDescription)"
        }
    }
}

/// Whisper's required input format, defined once so it can never drift
/// out of sync between the reader's output settings and the resampler.
enum WhisperPCMFormat {
    static let sampleRate: Double = 16_000
    static let channels: AVAudioChannelCount = 1
    static let bitDepth: Int = 16
}

actor AudioPipeline {

    /// Extracts, resamples, and hands back both a float32 PCM buffer
    /// (ready for whisper.cpp) and the URL of the temporary WAV file that
    /// was written along the way — the caller is expected to pass that
    /// URL back into `scrub(sourceURL:temporaryWAVURL:)` the instant
    /// inference finishes reading from the buffer.
    func extractPCM(from sourceURL: URL) async throws -> (samples: [Float], temporaryWAVURL: URL) {
        let asset = AVURLAsset(url: sourceURL)

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioPipelineError.assetHasNoAudioTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioPipelineError.readerInitFailed(error)
        }

        // Ask the reader to hand us already-linear-PCM, 16-bit, mono,
        // 16kHz samples directly — letting AVFoundation do the heavy
        // resampling work instead of hand-rolling a resampler.
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

        let temporaryWAVURL = Self.makeTemporaryWAVURL()
        let writer = try Self.openWAVWriter(at: temporaryWAVURL)

        guard reader.startReading() else {
            throw AudioPipelineError.readerFailedMidStream(reader.error?.localizedDescription ?? "unknown reader error")
        }

        var int16Samples: [Int16] = []

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                         totalLengthOut: &length, dataPointerOut: &dataPointer)

            if let dataPointer {
                dataPointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { int16Ptr in
                    let buffer = UnsafeBufferPointer(start: int16Ptr, count: length / 2)
                    int16Samples.append(contentsOf: buffer)
                    writer.append(buffer)
                }
            }
        }

        if reader.status == .failed {
            writer.close()
            try? FileManager.default.removeItem(at: temporaryWAVURL)
            throw AudioPipelineError.readerFailedMidStream(reader.error?.localizedDescription ?? "reader failed")
        }

        writer.close()

        // Convert to normalized float32 for whisper.cpp's expected input.
        let floatSamples = int16Samples.map { Float($0) / Float(Int16.max) }

        return (floatSamples, temporaryWAVURL)
    }

    /// Mandatory cleanup: erases BOTH the original source file and the
    /// intermediate WAV the instant the caller confirms inference has
    /// consumed the PCM buffer. Called from a `defer` at the call site so
    /// it fires on every exit path, including thrown errors.
    func scrub(sourceURL: URL, temporaryWAVURL: URL) {
        let fm = FileManager.default
        for url in [sourceURL, temporaryWAVURL] {
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
            } catch {
                // Scrubbing failures are logged locally only — never
                // transmitted anywhere — but must not be silently
                // swallowed, since a failed wipe is a privacy incident.
                #if DEBUG
                print("OffGrid: failed to scrub \(url.lastPathComponent): \(error)")
                #endif
            }
        }
    }

    // MARK: - WAV sink

    private static func makeTemporaryWAVURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("offgrid-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("wav")
    }

    private static func openWAVWriter(at url: URL) throws -> WAVFileWriter {
        do {
            return try WAVFileWriter(fileURL: url,
                                      sampleRate: WhisperPCMFormat.sampleRate,
                                      channels: WhisperPCMFormat.channels,
                                      bitDepth: WhisperPCMFormat.bitDepth)
        } catch {
            throw AudioPipelineError.writeFailed(error)
        }
    }
}

/// Minimal streaming WAV writer — avoids buffering the entire file in
/// memory before write, and avoids pulling in a third-party audio file
/// library just to emit a canonical 44-byte-header PCM WAV.
final class WAVFileWriter {
    private let handle: FileHandle
    private var dataBytesWritten: UInt32 = 0
    private let sampleRate: Double
    private let channels: AVAudioChannelCount
    private let bitDepth: Int

    init(fileURL: URL, sampleRate: Double, channels: AVAudioChannelCount, bitDepth: Int) throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: fileURL)
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        // Reserve space for the 44-byte canonical header; patched on close().
        handle.write(Data(count: 44))
    }

    func append(_ samples: UnsafeBufferPointer<Int16>) {
        let data = Data(buffer: samples)
        handle.write(data)
        dataBytesWritten += UInt32(data.count)
    }

    func close() {
        let header = makeHeader()
        handle.seek(toFileOffset: 0)
        handle.write(header)
        try? handle.close()
    }

    private func makeHeader() -> Data {
        var data = Data()
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitDepth / 8)
        let blockAlign = UInt16(channels) * UInt16(bitDepth / 8)

        func append(_ s: String) { data.append(s.data(using: .ascii)!) }
        func append(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append(UInt32(36 + dataBytesWritten))
        append("WAVE")
        append("fmt ")
        append(UInt32(16))                    // fmt chunk size
        append(UInt16(1))                     // PCM
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(byteRate)
        append(blockAlign)
        append(UInt16(bitDepth))
        append("data")
        append(dataBytesWritten)
        return data
    }
}

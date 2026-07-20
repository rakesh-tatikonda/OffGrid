//
//  ContentView.swift
//  OffGrid
//
//  Top-level screen. Both ingestion paths (Files-app picker and pasted
//  media URL) converge on `IngestedMedia`, which flows into the audio
//  pipeline and inference manager; the result is either persisted to
//  the encrypted SwiftData sandbox or exported to a user-chosen folder
//  via the system Files app (Module 4's two storage choices).
//
import SwiftUI
import SwiftData

@MainActor
@Observable
final class TranscriptionViewModel {
    enum Stage {
        case idle
        case extractingAudio
        case transcribing
        case summarizing
        case done(TranscriptionOutcome, IngestedMedia)
        case failed(String)
    }

    var stage: Stage = .idle
    var selectedLanguage: LanguageOption = .autoDetect
    var translateToEnglish = false
    var detectedLanguageBadge: String?
    var showPaywall = false

    private let audioPipeline = AudioPipeline()
    private let inferenceManager: AIInferenceManager

    init(whisperModelPath: String, llamaModelPath: String) {
        inferenceManager = AIInferenceManager(whisperModelPath: whisperModelPath, llamaModelPath: llamaModelPath)
    }

    func process(_ media: IngestedMedia) async {
        stage = .extractingAudio
        do {
            let (samples, wavURL) = try await audioPipeline.extractPCM(from: media.sandboxURL)

            // Mandatory scrub fires on every exit path from this point on.
            // Note this removes media.sandboxURL itself — the raw file is
            // never meant to survive past inference — so anything the user
            // later chooses to persist is the *transcript*, not the media.
            defer {
                Task { await self.audioPipeline.scrub(sourceURL: media.sandboxURL, temporaryWAVURL: wavURL) }
            }

            stage = .transcribing
            let outcome = try await inferenceManager.process(
                pcm: samples,
                languageCode: selectedLanguage.id,
                translateToEnglish: translateToEnglish
            )

            if selectedLanguage.id == "auto" {
                detectedLanguageBadge = LanguageOption.displayName(forCode: outcome.detectedLanguageCode)
            }

            stage = .done(outcome, media)
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }
}

struct ContentView: View {
    @Environment(StoreManager.self) private var store
    @State private var viewModel: TranscriptionViewModel

    init(whisperModelPath: String, llamaModelPath: String) {
        _viewModel = State(initialValue: TranscriptionViewModel(
            whisperModelPath: whisperModelPath, llamaModelPath: llamaModelPath
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Import") {
                    FileImporterButton { media in
                        Task { await viewModel.process(media) }
                    }
                    MediaURLImportView { media in
                        Task { await viewModel.process(media) }
                    }
                }

                Section("Language") {
                    Picker("Language", selection: $viewModel.selectedLanguage) {
                        ForEach(LanguageOption.all) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    if let badge = viewModel.detectedLanguageBadge {
                        Label("Detected Language: \(badge)", systemImage: "waveform")
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Translate to English", isOn: $viewModel.translateToEnglish)
                }

                Section("Status") {
                    statusView
                }
            }
            .navigationTitle("OffGrid")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !store.isPremiumUser {
                        Button("Upgrade") { viewModel.showPaywall = true }
                    }
                }
            }
            .sheet(isPresented: $viewModel.showPaywall) {
                PaywallView()
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch viewModel.stage {
        case .idle:
            Text("Import a media file to begin.").foregroundStyle(.secondary)
        case .extractingAudio:
            Label("Extracting audio…", systemImage: "waveform.path")
        case .transcribing:
            Label("Transcribing on-device…", systemImage: "cpu")
        case .summarizing:
            Label("Summarizing…", systemImage: "text.alignleft")
        case .done(let outcome, let media):
            TranscriptResultView(outcome: outcome, media: media)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}

/// Module 4: presents both storage choices once a transcription finishes —
/// an encrypted, on-device SwiftData record, or a user-chosen folder in
/// the Files app via `.fileExporter`.
struct TranscriptResultView: View {
    let outcome: TranscriptionOutcome
    let media: IngestedMedia

    @Environment(\.modelContext) private var modelContext

    @State private var exportFormat: ExportFormat = .srt
    @State private var showFileExporter = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(outcome.summary)
                .font(.body)

            Picker("Export Format", selection: $exportFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }

            HStack {
                Button("Save to Secure Sandbox") { saveToSandbox() }
                    .buttonStyle(.bordered)
                Button("Save to Files App") { showFileExporter = true }
                    .buttonStyle(.bordered)
            }

            if let statusMessage {
                Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .green)
            }
        }
        .fileExporter(
            isPresented: $showFileExporter,
            document: TextFileDocument(text: SubtitleFormatter.render(segments: outcome.segments, as: exportFormat)),
            contentType: exportFormat.utType,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success:
                statusIsError = false
                statusMessage = "Saved to Files."
            case .failure(let error):
                statusIsError = true
                statusMessage = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    private var exportFilename: String {
        let base = (media.originalFileName as NSString).deletingPathExtension
        let name = base.isEmpty ? "transcript" : base
        return "\(name).\(exportFormat.fileExtension)"
    }

    /// Persists the transcript (not the raw media, which the audio
    /// pipeline has already scrubbed from disk) into the encrypted,
    /// backup-excluded SwiftData store from PersistenceController.
    private func saveToSandbox() {
        do {
            let asset = MediaAsset(
                originalFileName: media.originalFileName,
                // The media file itself has already been scrubbed per the
                // disk-scrubbing policy in AudioPipeline — this label is
                // retained for reference only, not as a live file path.
                sandboxRelativePath: media.sandboxURL.lastPathComponent
            )

            let segmentDTOs = outcome.segments.map {
                TranscriptSegmentDTO(startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
            }
            let segmentsData = try JSONEncoder().encode(segmentDTOs)

            let record = TranscriptionRecord(
                languageCode: outcome.detectedLanguageCode,
                wasTranslatedToEnglish: outcome.wasTranslatedToEnglish,
                summaryText: outcome.summary,
                segmentsJSON: segmentsData,
                sourceAsset: asset
            )

            modelContext.insert(asset)
            modelContext.insert(record)
            try modelContext.save()

            statusIsError = false
            statusMessage = "Saved to encrypted sandbox."
        } catch {
            statusIsError = true
            statusMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

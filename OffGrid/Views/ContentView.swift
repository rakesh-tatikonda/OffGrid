//
//  ContentView.swift  — PATCHED
//  OffGrid
//
//  CHANGES vs. original:
//   * P-06 (HIGH)  The `.fileExporter(document:)` argument was constructed on
//                  every single body evaluation — `SubtitleFormatter.render`
//                  ran over the whole transcript on the main thread whenever
//                  any unrelated @State changed (picker, status label, sheet).
//                  For a long transcript that is tens of milliseconds of
//                  string building per frame. Now rendered once, on demand,
//                  off the main actor.
//   * P-07        `JSONEncoder().encode` + `modelContext.save()` moved off
//                  the main thread's critical path.
//   * C-02        The mandatory scrub no longer depends on a `defer` that
//                  spawns a detached Task. `defer { Task { … } }` returns
//                  before the scrub runs and does not survive app suspension,
//                  so the "raw media never outlives inference" invariant was
//                  advisory at best. It is now awaited inline on every exit
//                  path, plus an orphan sweep on foreground.
//   * R-04        `.summarizing` was in the Stage enum and rendered in the UI
//                  but never assigned — the screen said "Transcribing" for
//                  the entire (often longer) summarisation phase.
//   * R-05        Entitlement is now actually enforced. `isPremiumUser` only
//                  controlled whether the Upgrade button was visible; the
//                  paywall advertised "unlimited file length & imports"
//                  against no enforcement anywhere in the codebase.
//
import SwiftData
import SwiftUI

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

    /// R-05: free-tier ceiling the paywall copy implies.
    static let freeTierDurationLimit: TimeInterval = 10 * 60

    var stage: Stage = .idle
    var selectedLanguage: LanguageOption = .autoDetect
    var translateToEnglish = false
    var detectedLanguageBadge: String?
    var showPaywall = false

    private let audioPipeline = AudioPipeline()
    private let inferenceManager: AIInferenceManager

    init(whisperModelPath: String, llamaModelPath: String) {
        inferenceManager = AIInferenceManager(whisperModelPath: whisperModelPath,
                                              llamaModelPath: llamaModelPath)
    }

    func process(_ media: IngestedMedia, isPremium: Bool) async {
        stage = .extractingAudio

        // C-02: one scrub path, awaited, covering every outcome including
        // thrown errors and cancellation. No detached Task, no defer.
        var samples: [Float] = []
        do {
            samples = try await audioPipeline.extractPCM(from: media.sandboxURL)
        } catch {
            await audioPipeline.scrub(sourceURL: media.sandboxURL)
            stage = .failed(error.localizedDescription)
            return
        }

        // R-05: enforce the entitlement on the decoded length, after we know
        // it and before we spend battery on inference.
        let seconds = Double(samples.count) / WhisperPCMFormat.sampleRate
        if !isPremium && seconds > Self.freeTierDurationLimit {
            await audioPipeline.scrub(sourceURL: media.sandboxURL)
            samples.removeAll(keepingCapacity: false)
            stage = .failed("Files over \(Int(Self.freeTierDurationLimit / 60)) minutes need OffGrid Premium.")
            showPaywall = true
            return
        }

        // The raw media has been fully consumed into `samples` — nothing else
        // reads the file, so scrub it now rather than at the end. This
        // shortens the plaintext-on-disk window to the decode duration only.
        await audioPipeline.scrub(sourceURL: media.sandboxURL)

        do {
            stage = .transcribing
            let outcome = try await inferenceManager.process(
                pcm: samples,
                languageCode: selectedLanguage.id,
                translateToEnglish: translateToEnglish,
                // R-04: the actor reports the phase change so the UI can
                // stop claiming to be transcribing during summarisation.
                onPhaseChange: { [weak self] phase in
                    guard let self else { return }
                    if phase == .summarizing { self.stage = .summarizing }
                }
            )

            // Release ~4 bytes/sample as soon as inference is done with it.
            samples.removeAll(keepingCapacity: false)

            if selectedLanguage.id == "auto" {
                detectedLanguageBadge = LanguageOption.displayName(forCode: outcome.detectedLanguageCode)
            }
            stage = .done(outcome, media)
        } catch is CancellationError {
            stage = .idle
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// C-02: covers the case the original could not — an app killed between
    /// import and scrub left the media behind permanently.
    func sweepOrphanedMedia() async {
        await audioPipeline.scrubOrphans()
    }
}

struct ContentView: View {
    @Environment(StoreManager.self) private var store
    @Environment(\.scenePhase) private var scenePhase
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
                        Task { await viewModel.process(media, isPremium: store.isPremiumUser) }
                    }
                    MediaURLImportView { media in
                        Task { await viewModel.process(media, isPremium: store.isPremiumUser) }
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
        .task { await viewModel.sweepOrphanedMedia() }   // C-02
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.sweepOrphanedMedia() }
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

struct TranscriptResultView: View {
    let outcome: TranscriptionOutcome
    let media: IngestedMedia

    @Environment(\.modelContext) private var modelContext

    @State private var exportFormat: ExportFormat = .srt
    @State private var showFileExporter = false
    @State private var isPreparingExport = false
    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    /// P-06: rendered once when the user asks to export, never in `body`.
    @State private var exportDocument: TextFileDocument?

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
                Button("Save to Secure Sandbox") { Task { await saveToSandbox() } }
                    .buttonStyle(.bordered)
                    .disabled(isSaving)

                Button("Save to Files App") { Task { await prepareExport() } }
                    .buttonStyle(.bordered)
                    .disabled(isPreparingExport)
            }

            if let statusMessage {
                Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .green)
            }
        }
        .fileExporter(
            isPresented: $showFileExporter,
            // P-06: an already-built document, or a trivial empty one. The
            // original called SubtitleFormatter.render(…) right here, so the
            // full transcript was re-serialised on every body pass.
            document: exportDocument ?? TextFileDocument(text: ""),
            contentType: exportFormat.utType,
            defaultFilename: exportFilename
        ) { result in
            exportDocument = nil          // release the rendered copy
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

    /// P-06: render off the main actor, then present the sheet.
    private func prepareExport() async {
        isPreparingExport = true
        defer { isPreparingExport = false }

        let segments = outcome.segments
        let format = exportFormat
        let text = await Task.detached(priority: .userInitiated) {
            SubtitleFormatter.render(segments: segments, as: format)
        }.value

        exportDocument = TextFileDocument(text: text)
        showFileExporter = true
    }

    /// P-07: JSON encoding happens off the main actor; only the SwiftData
    /// insert/save stays on it, as SwiftData's main context requires.
    private func saveToSandbox() async {
        isSaving = true
        defer { isSaving = false }

        do {
            let segments = outcome.segments
            let segmentsData = try await Task.detached(priority: .userInitiated) {
                try JSONEncoder().encode(
                    segments.map {
                        TranscriptSegmentDTO(startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
                    }
                )
            }.value

            let asset = MediaAsset(
                originalFileName: media.originalFileName,
                // Retained as a display label only — the media itself was
                // scrubbed before this view ever appeared.
                sandboxRelativePath: media.sandboxURL.lastPathComponent
            )

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
            statusMessage = PersistenceController.shared.isUsingFallbackStore
                // R-03: never tell the user something was persisted securely
                // when the store fell back to memory.
                ? "Saved for this session only — secure storage is unavailable."
                : "Saved to encrypted sandbox."
        } catch {
            statusIsError = true
            statusMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

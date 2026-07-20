# OffGrid — Architecture & Build Notes

Offline-first iOS transcription/translation/summarization app. Swift 5.10,
SwiftUI, iOS 17+. No analytics, no third-party cloud SDKs.

## File layout

```
OffGrid/
├── OffGrid-Bridging-Header.h        # exposes CoreAIBridge.h to Swift
├── App/
│   └── OffGridApp.swift             # entry point, environment wiring
├── CoreAI/
│   ├── CoreAIBridge.h               # C-linkage contract (Swift <-> C++)
│   ├── CoreAIBridge.cpp             # whisper.cpp + llama.cpp lifecycle
│   └── AIInferenceManager.swift     # actor-isolated sequential orchestrator
├── Persistence/
│   └── PersistenceController.swift  # SwiftData + file protection + backup exclusion
├── Audio/
│   └── AudioPipeline.swift          # AVAssetReader -> 16kHz PCM -> scrub
├── Networking/
│   ├── URLStreamDownloader.swift    # the ONLY permitted network egress point
│   └── SandboxPaths.swift           # shared cache-directory helper for both importers
├── Billing/
│   └── StoreManager.swift           # StoreKit 2, local-only entitlement checks
├── Views/
│   ├── ContentView.swift            # screen + real sandbox-save / file-export wiring
│   ├── FileImporterView.swift       # security-scoped URL handshake
│   ├── MediaURLImportView.swift     # pasted-URL download with live progress bar
│   └── PaywallView.swift
├── Models/
│   ├── TranscriptionModels.swift    # @Model types
│   ├── LanguageOption.swift         # ISO 639-1 picker source of truth
│   └── IngestedMedia.swift          # shared metadata for both import paths
├── Export/
│   ├── SubtitleFormatter.swift      # SRT / VTT / TXT renderers
│   └── TextFileDocument.swift       # FileDocument wrapper powering .fileExporter
└── Resources/
    └── Info.plist.excerpt.xml       # merge into the real Info.plist
```

## Vendoring the native engines

This project does **not** include whisper.cpp or llama.cpp source — they're
large, independently-versioned C/C++ projects with their own build flags.
`CoreAIBridge.cpp` is written against their public C APIs
(`whisper_init_from_file_with_params`, `whisper_full`, `whisper_free`;
`llama_model_load_from_file`, `llama_init_from_model`, `llama_decode`,
`llama_free`). To build:

1. `git submodule add https://github.com/ggml-org/whisper.cpp ThirdParty/whisper.cpp`
2. `git submodule add https://github.com/ggml-org/llama.cpp ThirdParty/llama.cpp`
3. Add both as local Swift Package or source-file targets in Xcode, enable
   `WHISPER_COREML=1` when building whisper.cpp so the Core ML encoder path
   used by `cparams.use_gpu = true` is actually available.
4. Because whisper.cpp and llama.cpp both ship a `ggml.h`/`ggml.c`, link them
   as **separate targets**, not both compiled directly into the app target,
   to avoid duplicate-symbol errors.
5. Pin exact API signatures against whichever commit you vendor —
   both projects make small signature changes across releases; the
   bridge above matches their APIs as of early-2026 mainline.

## Models

Ship a Core ML–accelerated GGML whisper model (e.g. a small/base variant)
and a 4-bit quantized GGUF text model (e.g. Gemma 2B) inside
`Resources/Models/` in the app bundle so first launch requires no download.

## Security spec -> file mapping

| Requirement | File |
|---|---|
| Complete file protection + backup exclusion | `Persistence/PersistenceController.swift` |
| 16kHz mono PCM extraction + disk scrubbing | `Audio/AudioPipeline.swift` |
| whisper_free before llama_init, 200ms settle | `CoreAI/AIInferenceManager.swift` |
| Restricted network egress | `Networking/URLStreamDownloader.swift` |
| Local StoreKit 2 entitlement check | `Billing/StoreManager.swift` |
| Security-scoped file import | `Views/FileImporterView.swift` |
| Real-time download progress (Module 1) | `Views/MediaURLImportView.swift` |
| Dual-storage save: sandbox + Files app (Module 4) | `Views/ContentView.swift` (`TranscriptResultView`), `Export/TextFileDocument.swift` |

## Design note: raw media vs. transcript persistence

`AudioPipeline`'s mandatory scrub deletes the ingested media file (and its
intermediate WAV) the instant inference has consumed it — this happens
*before* the user ever sees the "Save to Secure Sandbox" / "Save to Files
App" choice. That's intentional: what Module 4 persists is the
**transcript**, never the raw audio/video, so `MediaAsset.sandboxRelativePath`
is retained only as a filename label for display, not a live file
reference. If a future requirement calls for keeping the source media
too, that means deliberately opting a given import out of the scrub
policy — it should not be a side effect of adding persistence.

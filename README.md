# OffGrid — Architecture & Build Notes

Offline-first iOS transcription/translation/summarization app. Swift 5.10,
SwiftUI, iOS 17+. No analytics, no third-party cloud SDKs.

> **This tree is the security-audited revision.** A full findings report lives
> at [`docs/SECURITY_AUDIT.md`](docs/SECURITY_AUDIT.md). Patched sources carry
> inline `S-xx` / `M-xx` / `P-xx` / `CI-xx` markers that tie each edit back to a
> numbered finding. Read the report before changing anything in `AudioPipeline`,
> `PersistenceController`, `SandboxPaths`, or `CoreAIBridge.mm` — several of
> those changes look cosmetic and are not.
>
> **The patched sources have not been compiled** — the audit was performed
> without a macOS toolchain, and `ThirdParty/` is empty here. Budget a
> build-and-fix pass. See "Known gaps" at the end.

## File layout

```
OffGrid/
├── OffGrid-Bridging-Header.h        # exposes CoreAIBridge.h to Swift
├── App/
│   └── OffGridApp.swift             # entry point, environment wiring
├── CoreAI/
│   ├── CoreAIBridge.h               # C-linkage contract (Swift <-> C++)
│   ├── CoreAIBridge.mm              # whisper.cpp + llama.cpp lifecycle
│   └── AIInferenceManager.swift     # actor-isolated sequential orchestrator
├── Persistence/
│   └── PersistenceController.swift  # SwiftData + file protection + backup exclusion
├── Audio/
│   └── AudioPipeline.swift          # AVAssetReader -> 16kHz PCM -> scrub
├── Networking/
│   ├── URLStreamDownloader.swift    # the ONLY permitted network egress point
│   └── SandboxPaths.swift           # protected ingest directory for both importers
├── Billing/
│   └── StoreManager.swift           # StoreKit 2, local-only entitlement checks
├── Views/
│   ├── ContentView.swift            # screen + sandbox-save / file-export wiring
│   ├── FileImporterView.swift       # security-scoped URL handshake
│   ├── MediaURLImportView.swift     # pasted-URL download with live progress bar
│   └── PaywallView.swift            # purchase + restore
├── Models/
│   ├── TranscriptionModels.swift    # @Model types
│   ├── LanguageOption.swift         # ISO 639-1 picker source of truth
│   └── IngestedMedia.swift          # shared metadata for both import paths
├── Export/
│   ├── SubtitleFormatter.swift      # SRT / VTT / TXT renderers
│   └── TextFileDocument.swift       # FileDocument wrapper powering .fileExporter
└── Resources/
    └── Info.plist.excerpt.xml       # reference only; project.yml generates the real plist
```

## Vendoring the native engines

This project does **not** include whisper.cpp or llama.cpp source — they're
large, independently-versioned C/C++ projects with their own build flags.
`CoreAIBridge.mm` is written against their public C APIs
(`whisper_init_from_file_with_params`, `whisper_full`, `whisper_free`;
`llama_model_load_from_file`, `llama_init_from_model`, `llama_decode`,
`llama_free`). To build:

1. `git submodule add https://github.com/ggml-org/whisper.cpp ThirdParty/whisper.cpp`
2. `git submodule add https://github.com/ggml-org/llama.cpp ThirdParty/llama.cpp`
3. `./scripts/fix-thirdparty-submodules.sh`
4. Because whisper.cpp and llama.cpp both ship a `ggml.h`/`ggml.c`, link them
   as **separate targets**, not both compiled directly into the app target,
   to avoid duplicate-symbol errors.
5. Pin exact API signatures against whichever commit you vendor —
   both projects make small signature changes across releases.

### ⚠️ Acceleration: read this before shipping (audit finding B-02)

The build as configured is **CPU-only, with no Accelerate**:

- `ThirdParty/Package.swift` excludes `ggml/src/ggml-metal` from both targets
- the whisper target also excludes `src/coreml`
- both define `GGML_USE_CPU=1`; whisper additionally defines `GGML_NO_ACCELERATE=1`
- `scripts/fix-thirdparty-submodules.sh` physically `rm -rf`s `ggml-metal`

The original `CoreAIBridge.mm` nonetheless set `cparams.use_gpu = true` and
`mparams.n_gpu_layers = 999`. ggml does not fail on that — it logs a warning
and silently falls back to scalar CPU. The result is inference running at a
small fraction of achievable speed, with sustained thermal throttling and
battery drain, and a realistic chance of watchdog or jetsam termination on a
long file.

The patched bridge gates those requests behind compile-time flags so the code
cannot lie about the build:

```
COREAI_HAVE_METAL   // define =1 only if ggml-metal is actually compiled in
COREAI_HAVE_COREML  // define =1 only if whisper's src/coreml is compiled in
```

Both default to `0`, which matches the current `Package.swift`. **This makes
the status quo honest; it does not make it fast.** To actually get
acceleration:

1. Stop excluding `ggml/src/ggml-metal` in `Package.swift` and stop deleting it
   in `fix-thirdparty-submodules.sh`.
2. Resolve the duplicate `default.metallib` collision the exclusion was working
   around — build the two engines as separate SwiftPM targets emitting distinct
   metallib names (the same separation step 4 above already requires).
3. Pass `-DCOREAI_HAVE_METAL=1` (and `-DCOREAI_HAVE_COREML=1` if you also
   re-enable whisper's Core ML encoder and ship the matching `.mlmodelc`).

Metal offload is typically a 5–20× improvement for llama.cpp on Apple silicon.
This is the single highest-leverage change available in this codebase.

## Models

Ship a GGML whisper model (e.g. a small/base variant) and a 4-bit quantized
GGUF text model (e.g. Gemma 2B) inside `Resources/Models/` in the app bundle so
first launch requires no download. `AIInferenceManager` now fails with an
explicit "model missing from this build" error if the bundle lookup returns
empty, rather than passing `""` down to the C layer (finding R-08).

## Security spec -> file mapping

| Requirement | File |
|---|---|
| Complete file protection + backup exclusion | `Persistence/PersistenceController.swift` |
| Data Protection on ingested media | `Networking/SandboxPaths.swift` |
| 16kHz mono PCM extraction + disk scrubbing | `Audio/AudioPipeline.swift` |
| whisper_free before llama_init, 200ms settle | `CoreAI/AIInferenceManager.swift` |
| Restricted network egress + redirect validation | `Networking/URLStreamDownloader.swift` |
| Local StoreKit 2 entitlement check + restore | `Billing/StoreManager.swift` |
| Security-scoped file import | `Views/FileImporterView.swift` |
| Real-time download progress (Module 1) | `Views/MediaURLImportView.swift` |
| Dual-storage save: sandbox + Files app (Module 4) | `Views/ContentView.swift`, `Export/TextFileDocument.swift` |

## Design note: raw media vs. transcript persistence

`AudioPipeline`'s mandatory scrub deletes the ingested media file the moment
inference has consumed it — before the user ever sees the "Save to Secure
Sandbox" / "Save to Files App" choice. That's intentional: what Module 4
persists is the **transcript**, never the raw audio/video, so
`MediaAsset.sandboxRelativePath` is retained only as a filename label for
display, not a live file reference.

Two changes from the original design here:

- **The intermediate WAV is gone** (finding S-04). `extractPCM` used to write a
  complete plaintext WAV of the decoded audio to `tmp/` and return its URL —
  and nothing ever read it. It existed only to be deleted. It now returns
  `[Float]` alone. If you ever want a debug dump, gate it behind `#if DEBUG`
  and write it with an explicit protection class.
- **Scrubbing is awaited, not deferred** (finding C-02). The original used
  `defer { Task { await scrub(…) } }`, which returns before the scrub runs and
  does not survive a background kill. It is now awaited on every exit path,
  with `scrubOrphans()` on app foreground as the backstop for process death.

What makes deletion meaningful is Data Protection, not overwriting. On
APFS-backed NAND an overwrite pass does not reliably reach the original
physical blocks. Because the ingest directory is created with a protection
class, unlinking the file destroys its per-file key and the residual ciphertext
is unrecoverable. That's why `SandboxPaths` matters as much as `scrub()` does.

## Known gaps

- **Nothing here has been compiled.** Expect a build-and-fix pass, most likely
  around Swift concurrency annotations.
- **llama.cpp API drift.** The bridge uses `llama_memory_clear` /
  `llama_get_memory`, which replaced an older `llama_kv_cache_clear`. Pin
  against the commit you actually vendor.
- **`freeTierDurationLimit`** in `ContentView.swift` is set to 10 minutes as a
  placeholder. The paywall advertises a limit that the original code never
  enforced anywhere; set this to whatever your business model actually intends.
- **Terms / Privacy URLs** in `PaywallView.swift` point at `example.com`.
  Replace before submission.
- **CI actions are still pinned to mutable tags.** See the TODO in
  `.github/workflows/ios-build.yml` (finding CI-04).
- **Check your git history for a committed `.p8`.** The original `.gitignore`
  named `AuthKey_P5P4S37T4B.p8`, disclosing that App Store Connect Key ID and
  suggesting the key was once in the working tree. Run:
  ```
  git log --all --full-history -- '*.p8' '*.p12' '*.mobileprovision'
  git log -p --all -S 'BEGIN PRIVATE KEY'
  ```
  If anything turns up, revoke the key in App Store Connect immediately.

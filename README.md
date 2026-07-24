# OffGrid — Architecture & Build Notes

Offline-first iOS transcription/translation/summarization app. Swift 5.10,
SwiftUI, iOS 17+. No analytics, no third-party cloud SDKs.

---

## ⚠️ START HERE — why a fresh checkout crashes on launch

If the app dies immediately on launch, before any UI, every time — and the
built `.app` is only a few hundred KB — nothing is wrong with the Swift code.
**The native engines and the models were never assembled into the project.**

`ThirdParty/whisper.cpp` and `ThirdParty/llama.cpp` are declared in
`.gitmodules` but ship empty. There is no `OffGrid/Resources/Models/` at all.
So:

- `Package.swift` targets point at empty directories → nothing native compiles
- `project.yml`'s `HEADER_SEARCH_PATHS` point at paths that don't exist
- `CoreAIBridge.mm`'s `#include "whisper.h"` / `"llama.h"` resolve to nothing
- `OffGridApp.swift`'s `Bundle.main.path(forResource:)` lookups return `""`

Both products are declared `.library(type: .dynamic)`, and dyld resolves
dynamic libraries **before `main()` runs** — before any SwiftUI code, before
`PersistenceController`, before anything in this repo executes. A missing
dylib therefore produces an identical crash in every build, patched or not:

```
dyld[…]: Library not loaded: @rpath/libWhisperEngine.dylib
Termination Reason: DYLD, [1] Library missing
```

### Fix

```bash
git submodule update --init --recursive
MODE=production ./scripts/setup-models.sh   # submodules + production models
```

> **If you unzipped this rather than cloning it**, there is no `.git`
> directory, so `git submodule update` has nothing to work with. Either clone
> the repository proper, or run `git init` and re-add the two submodules from
> `.gitmodules` before running the setup script.

Then verify the thing that was actually broken:

```bash
ls YourApp.app/Frameworks/     # must contain the two dylibs
```

Empty or missing means the submodules still didn't take, and you will get the
same dyld crash.

### If the IPA is ~300 KB

That is the same fault seen from the other side: the dynamic products were
**linked but not embedded**, so they never land in `Payload/…app/Frameworks/`.
The build goes green and the app dies in dyld. `project.yml` now carries
`embed: true` / `codeSign: true` on both package dependencies.

After `xcodegen generate`, confirm in Xcode: target -> General -> "Frameworks,
Libraries, and Embedded Content" -> both products must read **Embed & Sign**.
If your XcodeGen version does not honour `embed:` for package products, set it
there by hand.

Size checkpoints as you go:

| State | Expected |
|---|---|
| Linked but not embedded (broken) | ~300 KB |
| Embedded, no models | ~20 MB |
| Embedded + testing models | ~0.5-0.8 GB |
| Embedded + production models | ~2.0 GB |

CI now asserts on all of this after export — a bundle under 20 MB, a missing
`Frameworks/`, or a missing model file fails the build loudly instead of
shipping an IPA that crashes on launch.

### Models

Models are not in the repository and never should be — `.gitignore` excludes
`*.gguf`, `*.bin` and `OffGrid/Resources/Models/` so a 2 GB payload cannot
bloat every clone permanently.

Locally:

```bash
export LLAMA_URL="https://huggingface.co/<repo>/resolve/main/<file>.gguf"
export HF_TOKEN="hf_..."                    # only if the repo is gated
MODE=production ./scripts/setup-models.sh   # or MODE=testing
```

In CI, models now download from **public defaults with no configuration**, so
a fresh clone builds green. Three optional secrets override them:

```
MODEL_WHISPER_URL   -> OffGrid/Resources/Models/ggml-small-encoder.bin
MODEL_LLAMA_URL     -> OffGrid/Resources/Models/gemma-2b-q4_k_m.gguf
MODEL_AUTH_TOKEN    -> optional bearer token for gated/private sources
```

Both filenames are load-bearing — they must match the
`Bundle.main.path(forResource:)` lookups in `OffGridApp.swift` exactly,
whatever the upstream file was called.

The defaults are third-party Hugging Face repos. They are fine for getting a
build running; they are not something to depend on for releases.

**Mirror the weights to your own storage rather than pulling from Hugging
Face in CI.** A release asset or a presigned S3/GCS URL removes the gating and
token problem, survives an upstream repo being renamed or deleted, avoids rate
limits, and makes builds reproducible. Fetching a third party's file on every
release build makes your pipeline depend on their uptime and their naming.

### Diagnostic build (verify embedding without models)

To confirm the `embed: true` fix worked without sourcing 2 GB of weights
first, run the workflow manually with **skip_models** checked:

    Actions -> iOS Build and Export -> Run workflow -> skip_models ✓

The model download is skipped, the model assertions are relaxed, but the
`Frameworks/` check still runs. Expect a **~20 MB** IPA. If it is still a few
hundred KB, embedding did not take and the build fails with that message
rather than producing a crashing artifact.

Do not use this for anything you intend to install — an IPA built this way
will launch and then fail at inference with "model missing from this build".

### Text model: licence and prompt format

Two things to settle before shipping, neither of which is a technical problem:

- **Licence.** The original Gemma releases ship under Google's Gemma Terms of
  Use, *not* Apache 2.0, and those terms carry use restrictions you have to
  pass through to your own users. For a paid App Store app that is a real
  question, not a formality. Newer Gemma generations are Apache 2.0, which is
  considerably simpler to redistribute commercially. Check the licence on the
  exact model card you pull from — and note this is a legal question, so treat
  the above as a prompt to verify rather than as advice.
- **Prompt format.** `coreai_llama_summarize` hardcodes Gemma's chat template
  (`<start_of_turn>user` … `<end_of_turn><start_of_turn>model`). Staying in
  the Gemma family keeps it valid. Any other family will still run and emit
  text, but summaries will be poor until you swap the template.

### Two local-build gotchas

1. **Signing.** `project.yml` hardcodes `CODE_SIGN_IDENTITY: "Apple
   Distribution"` with `${APPLE_TEAM_ID}` / `${PROVISIONING_PROFILE_NAME}`,
   which only CI populates. Locally they expand empty. **Build for a Simulator
   target first** — signing isn't required there, and the build is CPU-only
   anyway so you lose nothing on inference. Use a local-only override for
   device builds rather than editing `project.yml`, or CI breaks.
2. **`freeTierDurationLimit`.** `ContentView.swift` enforces a 10-minute cap
   for non-premium users (finding R-05). Without a StoreKit configuration file
   `isPremiumUser` is `false`, so longer test files are rejected before
   inference — which looks like a bug. Set it to `.infinity` while testing.

### Expected size once assembled

| Config | Whisper | Text model | Total |
|---|---|---|---|
| Testing | `tiny.en` ~75 MB | 0.5–1B Q4_K_M ~350–700 MB | **~0.5–0.8 GB** |
| Production | `small` ~488 MB | Gemma 2B Q4_K_M ~1.5 GB | **~2.0 GB** |

App code and both dylibs together are only ~20 MB; the models are ~99% of the
bundle. Apple's cap is 4 GB uncompressed, so production fits with roughly half
the headroom spent. Quantised weights compress poorly, so the `.ipa` will not
be much smaller than the installed size.

---

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

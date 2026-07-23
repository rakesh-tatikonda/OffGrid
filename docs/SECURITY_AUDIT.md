# OffGrid / CapSureTranscribe — iOS Security Audit & Performance Review

**Reviewer role:** Principal iOS Engineer / Mobile AppSec
**Scope:** `OffGrid-main` — 15 Swift files, 1 Obj-C++ bridge, SwiftPM vendoring manifest, XcodeGen project, GitHub Actions release pipeline (~2,800 LOC total)
**Date:** 23 July 2026

---

## 0. Application context (resolved from the code — your brief had placeholders)

| Field | Value | Source |
|---|---|---|
| Language | Swift 5.10 + Objective-C++ (`.mm`) bridge to C/C++ | `project.yml:27`, `CoreAIBridge.mm` |
| UI framework | SwiftUI, mixed `@Observable` / `ObservableObject` | `ContentView.swift`, `FileImporterView.swift` |
| Minimum iOS | **17.0** | `project.yml:6`, `ThirdParty/Package.swift:7` |
| Persistence | SwiftData (SQLite, WAL mode) | `PersistenceController.swift` |
| Native engines | whisper.cpp + llama.cpp, **CPU-only build** | `ThirdParty/Package.swift` |
| Bundle ID | `com.Fortress.CapSureTranscribe` | `project.yml:26` |

**Threat model.** This is a privacy-first, offline transcription app. Its stated security posture — no telemetry, one network egress point, mandatory media scrubbing, encrypted local store — is unusually well thought through *in the comments*. Most of what follows are places where the implementation does not deliver what the comment next to it claims. Those gaps are more dangerous than an app with no claims at all, because the design has been signed off on the strength of the comments.

**Headline result:** no hardcoded API keys, no secrets in source, ATS is correctly left at its secure default, no analytics SDKs, no `UIBackgroundModes`, no CloudKit sync, `UIFileSharingEnabled` correctly `false`. The basics your brief asked about are genuinely clean. The real problems are elsewhere: **three of the app's four stated privacy guarantees do not hold as implemented**, and there is an untrusted-input-driven crash chain from imported media through to the C++ layer.

---

## 🚨 iOS Security Flaws & Patches

### Severity summary

| ID | Finding | File | Risk |
|---|---|---|---|
| S-01 | WAL/SHM sidecars never receive file protection | `PersistenceController.swift` | **High** |
| S-12 | Unbounded prompt overruns llama.cpp KV cache → abort | `CoreAIBridge.mm` | **High** |
| S-04 | Full plaintext audio written to `tmp/` for no consumer | `AudioPipeline.swift` | **High** |
| S-05 | Ingested media stored with no Data Protection class | `SandboxPaths.swift` | **High** |
| CI-01 | Signing keychain password is a public value | `ios-build.yml` | **Medium** |
| CI-02 | Signing private key decrypted into a shell pipe; passphrase in argv | `ios-build.yml` | **Medium** |
| S-13 | Prompt injection from transcript content into summariser | `CoreAIBridge.mm` | **Medium** |
| S-08/09 | No HTTP status check, no size ceiling on downloads | `URLStreamDownloader.swift` | **Medium** |
| S-07 | Redirects not re-validated after the `https` check | `URLStreamDownloader.swift` | **Medium** |
| CI-03 | `security import -A` grants all applications key access | `ios-build.yml` | **Medium** |
| S-02 | `.complete` protection breaks writes on screen lock | `PersistenceController.swift` | **Medium** |
| S-06 | "Scrub" failures silent in Release; "wipe" claim inaccurate | `AudioPipeline.swift` | **Medium** |
| CI-04 | Actions pinned to mutable tags, no `permissions:` block | `ios-build.yml` | **Medium** |
| S-14/16 | No import size ceiling; unsanitised path extension | `FileImporterView.swift`, `SandboxPaths.swift` | **Low-Med** |
| CI-06 | Signing keychain never destroyed after the job | `ios-build.yml` | **Low-Med** |
| S-17 | ASC API **Key ID** disclosed in `.gitignore` | `.gitignore` | **Low** |

---

### S-01 — SwiftData WAL and SHM files are never protected (High)

**Location:** `Persistence/PersistenceController.swift:79-99`

The file that exists specifically to harden the store contains a comment explaining exactly why the `-wal` and `-shm` sidecars must be protected — and then skips them.

```swift
// ORIGINAL — the guard clause silently no-ops on the files that matter
private static func hardenStoreOnDisk(at storeURL: URL) throws {
    let sidecars = [storeURL, walURL(for: storeURL), shmURL(for: storeURL)]

    for var url in sidecars where FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        // ...
    }
}
```

Called at `init` line 48, immediately after `ModelContainer(...)`. At that moment SQLite has typically not yet created `OffGrid.sqlite-wal` or `-shm` — they appear on first write. `fileExists` returns `false`, the loop body never runs for them, and nothing ever revisits the question.

**Risk — local / at-rest.** In WAL journalling mode, every committed-but-not-yet-checkpointed transcript lives in the `-wal` file, sometimes for the app's entire lifetime. On a locked-but-booted device, files at the default `completeUntilFirstUserAuthentication` class are readable by anything that can reach the filesystem — a jailbreak, a forensic acquisition tool, or a logic exploit in another process. The main `.sqlite` is protected and looks reassuring on inspection; the sidecar next to it holding the same user speech is not.

**Patch** — apply protection to the *containing directory* before the store exists, so every file SQLite creates inherits the class:

```swift
private static func prepareSecureDirectory() throws -> URL {
    guard let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first else {
        throw PersistenceError.containerDirectoryUnavailable
    }
    var directory = appSupport.appendingPathComponent(directoryName, isDirectory: true)

    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])   // S-01 + S-02

    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    return directory
}
```

Plus `reassertProtection(in:)`, which sweeps the directory after container creation to catch anything an older build left unprotected. Full file: `patched/Persistence/PersistenceController.swift`.

**Why this secures it:** directory-level protection classes are inherited at file-creation time by the kernel, so there is no window and no ordering dependency. The original's approach — enumerate a hardcoded list of filenames after the fact — can only ever protect files that already exist.

---

### S-02 — `.complete` protection makes the app fail on screen lock (Medium)

**Location:** `PersistenceController.swift:85`

`FileProtectionType.complete` revokes access to a file the moment the device locks, *including for already-open file descriptors*. SwiftData holds the store open for the app's lifetime. A user who starts a 40-minute transcription and locks their phone comes back to write failures.

**Patch:** `.completeUnlessOpen` (shown above). It keeps an already-open handle usable while still refusing a cold open on a locked device — which is the property that matters against at-rest device theft. `.complete` is the right choice only for data you open, read, and close within a foreground interaction.

---

### S-04 — A full plaintext copy of the user's audio is written to `tmp/`, and nothing reads it (High)

**Location:** `Audio/AudioPipeline.swift:76-77, 97, 108, 145-154` and `WAVFileWriter`

`extractPCM` writes a complete 16 kHz WAV of the decoded audio to `FileManager.default.temporaryDirectory`, returns its URL, and — tracing every call site — **nothing ever opens it**. `ContentView` receives `wavURL` at line 42 for the sole purpose of passing it back to `scrub()` at line 49. The file is created only to be deleted.

```swift
// ORIGINAL
let temporaryWAVURL = Self.makeTemporaryWAVURL()
let writer = try Self.openWAVWriter(at: temporaryWAVURL)   // ← written, never read
...
return (floatSamples, temporaryWAVURL)
```

**Risk — local.** For an app whose core promise is "nothing ever leaves your device and nothing lingers", this doubles the plaintext-at-rest window for the most sensitive artefact in the system, for zero functional benefit. `FileManager.createFile(atPath:contents:)` applies no protection attributes, so the WAV sits at the default class. If the process is killed between write and scrub — jetsam during inference is a realistic outcome given M-01 below — the file survives indefinitely with no cleanup path.

**Patch:** removed entirely. `extractPCM` now returns `[Float]` only.

```swift
func extractPCM(from sourceURL: URL) async throws -> [Float] { ... }
```

**Why this secures it:** the safest handling of a sensitive intermediate is not to create it. This also removes ~1 GB of disk writes per hour of audio and the associated battery cost. If a debug WAV dump is ever genuinely wanted, gate it behind `#if DEBUG` and write it with `.completeUnlessOpen`.

---

### S-05 — Ingested media has no Data Protection class (High)

**Location:** `Networking/SandboxPaths.swift:16-23`

```swift
// ORIGINAL — no `attributes:` argument, so files inherit the default class
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
```

Every imported video and every downloaded media file lands here. The directory comment reasons carefully about *visibility* (Caches is not exposed via the Files app) and *purging*, but never about *encryption at rest*.

This is what makes S-06 matter. The `scrub()` comment says the source is "wiped from physical storage" — but on APFS-backed NAND, `removeItem` unlinks; it does not overwrite, and an overwrite would not reliably reach the original physical blocks anyway because of wear levelling and copy-on-write. **The thing that actually makes a deletion unrecoverable on iOS is Data Protection**: destroying the inode destroys the per-file key, rendering residual ciphertext meaningless. Without a protection class on the file, deletion is just an unlink and the delete-then-it's-gone claim does not hold.

**Patch:**

```swift
private static let resolvedIngestDirectory: URL = {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ingested", isDirectory: true)
    do {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
    } catch CocoaError.fileWriteFileExists {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: dir.path)
    } catch {
        log.fault("could not create ingest directory: \(error.localizedDescription, privacy: .public)")
    }
    var mutable = dir
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try? mutable.setResourceValues(values)
    return dir
}()
```

---

### S-06 — Scrub failures are invisible in production; the "wipe" claim is inaccurate (Medium)

**Location:** `AudioPipeline.swift:126-133`

```swift
// ORIGINAL
} catch {
    // "...must not be silently swallowed, since a failed wipe is a privacy incident."
    #if DEBUG
    print("OffGrid: failed to scrub \(url.lastPathComponent): \(error)")
    #endif
}
```

The comment states the requirement and the `#if DEBUG` immediately violates it. In Release — the only build where a privacy incident can affect a real user — the failure is silent.

**Patch:**

```swift
} catch {
    Self.log.error(
        "scrub failed for \(sourceURL.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
}
```

`OSLog` rather than `print`: structured, respects the unified logging privacy model, and `.private` redacts the filename in sysdiagnose captures. `print` writes to stdout, is visible to anyone with the device attached to Console.app, and is not redactable.

I also added `scrubOrphans()`, invoked on app foreground. The original's cleanup was a `defer` in `ContentView.process` — see C-02 — which does not survive a background kill, so an app terminated mid-inference left the raw media behind permanently with nothing to ever collect it.

---

### S-07 / S-08 / S-09 — Download path: no redirect re-validation, no status check, no size ceiling (Medium)

**Location:** `Networking/URLStreamDownloader.swift:65-76, 110-124`

```swift
// ORIGINAL — scheme is checked once, on the URL the user typed
guard remoteURL.scheme == "https" else {
    continuation.finish(throwing: URLError(.unsupportedURL)); return
}
let task = restrictedSession.downloadTask(with: remoteURL)
```

Three gaps:

1. **S-07 — redirects.** `URLSession` follows redirect chains transparently. The scheme check on the typed URL says nothing about where the bytes come from. A link shortener or an open redirector can steer the fetch into RFC 1918 space, `127.0.0.1`, or `169.254.0.0/16` — the user's own LAN, reachable from their device but not from the internet.
2. **S-08 — status codes.** `didFinishDownloadingTo` fires for a 404 as readily as a 200. The original moved that error page into the sandbox and handed it downstream as media.
3. **S-09 — size.** Nothing bounds the transfer. A server that streams indefinitely fills the device.

**Patch (excerpt — full file in `patched/Networking/`):**

```swift
func urlSession(_ session: URLSession, task: URLSessionTask,
                willPerformHTTPRedirection response: HTTPURLResponse,
                newRequest request: URLRequest,
                completionHandler: @escaping (URLRequest?) -> Void) {
    guard let url = request.url,
          url.scheme?.lowercased() == "https",
          let host = url.host,
          !Self.isPrivateOrLoopback(host) else {
        let id = task.taskIdentifier
        let host = request.url?.host ?? "unknown host"
        completionHandler(nil)                       // refuse the hop
        Task { [owner] in await owner?.fail(DownloadError.redirectBlocked(host), forTaskID: id) }
        return
    }
    completionHandler(request)
}
```

plus status-code and size checks on the first `didWriteData` callback, and a running-total ceiling for chunked responses that declare no length.

> **Implementation gotcha worth knowing:** the natural place to vet a response is `urlSession(_:dataTask:didReceive:completionHandler:)` — but that method belongs to `URLSessionDataDelegate`, and `URLSessionDownloadDelegate` does **not** inherit from it. Implementing it on a download-task delegate gives you a method that compiles, reads correctly in review, and is never called. I made exactly that mistake in the first draft of this patch. For download tasks the earliest reliable hook is the first `didWriteData` callback, where `downloadTask.response` is already populated.

**Why this secures it:** validating only the URL the user typed protects against nothing an attacker controls, because an attacker who can get a URL pasted can also control what it redirects to. The check has to happen on every hop.

Two related hardening changes in the same file: `allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess` were both `true`, meaning a multi-hundred-megabyte fetch would proceed over cellular and in Low Data Mode without asking. Both are now `false`. `tlsMinimumSupportedProtocolVersion` is pinned to `.TLSv12` explicitly rather than relying on a platform default that a future deployment-target change could widen.

---

### S-12 — Unbounded prompt overruns the llama.cpp context window (High)

**Location:** `CoreAI/CoreAIBridge.mm:184-203`

```cpp
// ORIGINAL
const std::string prompt = "<start_of_turn>user\n... " + std::string(transcript_utf8) + "...";
std::vector<llama_token> tokens(prompt.size() + 32);
const int n_tokens = llama_tokenize(vocab, prompt.c_str(), ..., /*parse_special=*/true);
tokens.resize(n_tokens);
llama_batch batch = llama_batch_get_one(tokens.data(), n_tokens);   // ← entire prompt, one batch
if (llama_decode(bundle->ctx, batch) != 0) { return nullptr; }
```

The context is created with `n_ctx = 4096` (line 166) and llama.cpp's default `n_batch` of 512. The prompt is the entire transcript. Roughly 20 minutes of speech exceeds 4,096 tokens; the app advertises "unlimited file length".

Two independent failures: the batch exceeds `n_batch`, and the KV cache overruns `n_ctx`. llama.cpp's response to both is an assertion — which in a Release iOS build is `abort()`, not a returned error code. `llama_decode`'s non-zero return is never reached.

**Risk — untrusted input.** Media content is attacker-influenceable on the pasted-URL path and user-supplied on the import path. A long-enough file is a reliable remote crash. Beyond availability, writing past a KV cache boundary is exactly the class of memory-safety condition worth taking seriously in a C++ dependency.

**Patch — truncate to a computed budget, then feed in `n_batch`-sized chunks:**

```cpp
const int32_t budget = bundle->n_ctx
                     - (int32_t)prefix_tokens.size()
                     - (int32_t)suffix_tokens.size()
                     - kMaxNewTokens - kScaffoldReserve;
if (budget <= 0) return nullptr;

if ((int32_t)content_tokens.size() > budget) {
    content_tokens.resize((size_t)budget);
}

const int32_t total = (int32_t)prompt.size();
for (int32_t offset = 0; offset < total; offset += bundle->n_batch) {
    const int32_t chunk = std::min(bundle->n_batch, total - offset);
    llama_batch batch = llama_batch_get_one(prompt.data() + offset, chunk);
    if (llama_decode(bundle->ctx, batch) != 0) return nullptr;
}
```

Truncation is a stopgap, not the right long-term answer — a production summariser should map-reduce over chunks. But it converts an abort into a degraded-but-correct result, which is the difference between a crash report and a slightly shorter summary.

Related, same file: **M-08**, the KV cache was never cleared between `coreai_llama_summarize` calls, so a second summarisation in one session continued from the first's state and consumed the window monotonically. Now `llama_memory_clear` at entry.

---

### S-13 — Prompt injection from transcript content into the summariser (Medium)

**Location:** `CoreAIBridge.mm:184-196`

The transcript is concatenated directly into the Gemma chat template and tokenised with `parse_special=true`. That flag tells llama.cpp to interpret control-token strings in the input **as actual control tokens**. A speaker who says — or a doctored media file whose audio track contains — the literal turn-delimiter sequence closes the user turn and opens their own.

**Risk.** The summariser is local, so this is not data exfiltration. But the summary is what the user reads and what gets persisted, and an attacker-authored media file can make it say whatever they want while looking like the app's own output. For a tool marketed on trustworthiness, that matters.

**Patch — tokenise scaffolding and untrusted content separately, with different flags:**

```cpp
std::vector<llama_token> prefix_tokens  = tokenize(prefix,           true,  /*parse_special=*/true);
std::vector<llama_token> content_tokens = tokenize(transcript_utf8,  false, /*parse_special=*/false);
std::vector<llama_token> suffix_tokens  = tokenize(suffix,           false, /*parse_special=*/true);
```

With `parse_special=false`, a literal `<end_of_turn>` in recognised speech tokenises as ordinary text. The prompt also now wraps the content in `<transcript>` delimiters and instructs the model to treat it strictly as data — defence in depth, since instruction-based defences alone are not reliable. The tokenisation flag is the control that actually holds.

---

### S-14 / S-16 — No import ceiling; unsanitised path extension (Low-Medium)

**Location:** `Views/FileImporterView.swift:56`, `Networking/SandboxPaths.swift:28-32`

Nothing bounds what a single import writes into Caches. And `newSandboxURL` takes the extension from a URL that, on the download path, is fully attacker-controlled:

```swift
// ORIGINAL
.appendingPathExtension(sourceURL.pathExtension.isEmpty ? "tmp" : sourceURL.pathExtension)
```

`appendingPathExtension` percent-encodes rather than resolving traversal, so this is not directly exploitable — but an unfiltered attacker-controlled component in a filesystem path is the kind of primitive you close on principle rather than reason about case by case.

**Patch:**

```swift
static func newSandboxURL(preservingExtensionOf sourceURL: URL) -> URL {
    let allowed = CharacterSet.alphanumerics
    let safe = sourceURL.pathExtension.unicodeScalars
        .filter { allowed.contains($0) }.map(String.init).joined()
    let ext = (safe.isEmpty || safe.count > 10) ? "tmp" : safe.lowercased()
    return ingestedMediaDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: false)
        .appendingPathExtension(ext)
}
```

Plus a 4 GB pre-copy size check in `FileImportCoordinator` and a 2 GB transfer ceiling in `URLStreamDownloader`, both checked *before* bytes are written.

---

### S-17 — App Store Connect Key ID disclosed in `.gitignore` (Low, but act on it)

**Location:** `.gitignore:7`

```
AuthKey_P5P4S37T4B.p8
```

The Key ID `P5P4S37T4B` is now in version control permanently. The ID alone is not a credential — authentication needs the `.p8` private key and the issuer ID as well — so this is information disclosure, not a breach.

What it tells me is that the `.p8` was at some point sitting in the working tree, which is exactly how private keys end up committed. **Two things to do:**

1. Run `git log --all --full-history -- '*.p8'` and `git log -p --all -S 'BEGIN PRIVATE KEY'` against the real repository. I could not check — the archive you sent has no `.git` directory. If anything turns up, revoke that key in App Store Connect immediately; history rewriting is not sufficient once a key has been pushed.
2. Replace the specific filename with a generic pattern so no ID is disclosed:

```gitignore
*.p8
AuthKey_*.p8
*.p12
*.mobileprovision
*.cer
```

---

### Clean findings — things your brief asked about that are genuinely fine

Worth stating explicitly so these don't get re-audited:

- **No hardcoded API keys or secrets anywhere in source.** Grepped for key/token/secret/password/PEM-header patterns across all Swift, headers, `.mm`, plists and YAML. Clean.
- **ATS is correctly left at its secure default.** No `NSAppTransportSecurity` key, no `NSAllowsArbitraryLoads`. `Info.plist.excerpt.xml` explicitly documents why. This is done right.
- **No sensitive data in `UserDefaults`.** `UserDefaults` is not used at all.
- **Keychain is not used** — and correctly so. There is no credential to store; StoreKit 2 entitlements live in the App Store receipt, not in app-managed storage. Adding a Keychain layer here would be a downgrade.
- **`Transaction.currentEntitlements` verification is correct.** Binding `case .verified` is the right check, and `revocationDate == nil` correctly excludes refunded purchases. (`checkVerified` at line 87 is a pure no-op whose doc comment claims otherwise — removed as R-11, but it was never a vulnerability.)
- **No analytics, no third-party SDKs, no CloudKit** (`cloudKitDatabase: .none` is explicit), **no `UIBackgroundModes`**, `UIFileSharingEnabled: false`, `LSSupportsOpeningDocumentsInPlace: false`. All correct.
- **`AVAssetReader` output settings** are pinned to exactly the format whisper expects, with no format-drift risk. Well done.

---

## ⚡ Performance & Memory Optimizations

### M-01 — Triple-buffered audio: ~3 bytes of RAM per sample at peak (Critical)

**Bottleneck:** `AudioPipeline.swift:83-111`

```swift
// ORIGINAL
var int16Samples: [Int16] = []                    // grows to the whole file
while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
    int16Samples.append(contentsOf: buffer)       // no reserveCapacity → repeated realloc
    writer.append(buffer)                         // ...and a full disk copy (S-04)
}
let floatSamples = int16Samples.map { Float($0) / Float(Int16.max) }   // second full array
```

At the `map`, both arrays are live: 2 bytes/sample as `Int16` plus 4 bytes/sample as `Float`. For one hour of 16 kHz mono that is 115 MB + 230 MB = **345 MB resident**, on top of the loaded whisper model, at the exact moment inference is about to start. On a 3 GB device the per-app jetsam limit is roughly 1.4 GB. The `WAVFileWriter` doc comment says it "avoids buffering the entire file in memory before write" — which is true of the writer and false of the function containing it.

`append(contentsOf:)` with no `reserveCapacity` also means log₂(n) reallocations, each copying the entire array so far.

**Optimized:**

```swift
var samples = [Float]()
if seconds.isFinite, seconds > 0 {
    samples.reserveCapacity(Int(seconds * WhisperPCMFormat.sampleRate) + 4_096)
}
var int16Scratch = [Int16]()      // reused across iterations
var floatScratch = [Float]()

while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
    try autoreleasepool {
        // ... safe copy into int16Scratch ...
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
```

**Expected gain:** peak footprint for the decode stage drops from ~3 bytes/sample to ~4 bytes/sample in a *single* pre-sized array — about **65% lower peak RSS** — with zero growth reallocations and no disk writes. The `vDSP` conversion replaces a scalar `map` over tens of millions of elements with NEON-vectorised Accelerate calls: **roughly 4-8x faster** on that stage, and it eliminates one full-array allocation. Together with the `autoreleasepool` (M-03), this is the difference between reliably transcribing a two-hour file and being jetsam-killed partway through.

---

### M-02 — Heap over-read on non-contiguous `CMBlockBuffer` (Critical, memory safety)

**Bottleneck:** `AudioPipeline.swift:88-98`

```swift
// ORIGINAL
var length = 0
var dataPointer: UnsafeMutablePointer<Int8>?
CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                            lengthAtOffsetOut: nil,        // ← discarded
                            totalLengthOut: &length,       // ← used instead
                            dataPointerOut: &dataPointer)
if let dataPointer {
    dataPointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { ... }
}
```

Two defects in four lines:

1. `lengthAtOffsetOut` is the number of **contiguous** bytes available at the returned pointer. `totalLengthOut` is the length of the entire logical buffer, which may be assembled from several disjoint memory blocks. Passing `nil` for the former and then reading `totalLength` bytes off the pointer is a heap over-read on any segmented buffer. `CMBlockBuffer` segmentation is common with compressed containers and hardware decode paths, so this is not theoretical — it is a latent crash that shows up on some files and some devices.
2. `withMemoryRebound(to: Int16.self, ...)` on an `Int8` pointer with no alignment guarantee is undefined behaviour. It happens to work on arm64 for 2-byte loads today.

**Optimized:**

```swift
let byteCount = CMBlockBufferGetDataLength(blockBuffer)
guard byteCount >= MemoryLayout<Int16>.size else { return }
let frameCount = byteCount / MemoryLayout<Int16>.size

let status = int16Scratch.withUnsafeMutableBytes { raw -> OSStatus in
    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0,
                               dataLength: frameCount * MemoryLayout<Int16>.size,
                               destination: raw.baseAddress!)
}
guard status == kCMBlockBufferNoErr else { throw AudioPipelineError.decodeBufferUnreadable }
```

**Expected gain:** correctness, primarily — this removes a real over-read. `CMBlockBufferCopyDataBytes` walks the segment list itself and lands the data in a correctly-aligned `[Int16]`. The copy cost is negligible next to the decode it sits inside, and it is more than repaid by the scratch-buffer reuse.

---

### M-03 — No autorelease pool in the decode loop

**Bottleneck:** `AudioPipeline.swift:85-100`

`copyNextSampleBuffer()` and the CoreMedia calls around it produce autoreleased objects. In a `while` loop with no pool, the enclosing pool does not drain until the whole function returns — so the loop's peak footprint tracks the entire file rather than one chunk.

**Optimized:** each iteration's body wrapped in `try autoreleasepool { ... }`.

**Expected gain:** bounds transient allocation to one sample buffer instead of all of them. On a long file this is hundreds of megabytes of deferred deallocation avoided — and it compounds with M-01, since both peaks occur at the same moment.

---

### P-06 — The full transcript is re-serialised on every SwiftUI body pass (High)

**Bottleneck:** `ContentView.swift:181-186`

```swift
// ORIGINAL
.fileExporter(
    isPresented: $showFileExporter,
    document: TextFileDocument(text: SubtitleFormatter.render(segments: outcome.segments, as: exportFormat)),
    ...
)
```

The `document:` argument is an ordinary eagerly-evaluated parameter. It is constructed **every time `body` runs**, not when the sheet is presented. `body` re-runs on every `@State` change in this view — changing the export format picker, a status message appearing, the sheet flag toggling — and on any parent invalidation.

`SubtitleFormatter.render` walks every segment, builds one intermediate `String` per segment via `map`, then joins them. For a two-hour transcript that is thousands of segments and hundreds of kilobytes of string building, **on the main thread, per frame**. This is the single most likely cause of scroll stutter and unresponsive taps on the results screen.

**Optimized:** render once, on demand, off the main actor:

```swift
@State private var exportDocument: TextFileDocument?

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

.fileExporter(isPresented: $showFileExporter,
              document: exportDocument ?? TextFileDocument(text: ""), ...)
```

**Expected gain:** removes an O(segments) main-thread workload from the render path entirely. On a long transcript this is the difference between a 60 fps screen and one dropping frames on every interaction. The document is released after export rather than being retained for the view's lifetime.

---

### P-09 — Quadratic-ish string building in `SubtitleFormatter`

**Bottleneck:** `SubtitleFormatter.swift:32-51`

`segments.map { ... }.joined(separator:)` allocates one `String` per segment, then a second full buffer for the join. `AIInferenceManager.swift:81` has the same pattern (`segments.map(\.text).joined(separator: " ")`).

**Optimized:** single accumulator with reserved capacity:

```swift
var out = String()
out.reserveCapacity(segments.count * 96)
for (index, segment) in segments.enumerated() {
    if index > 0 { out += "\n\n" }
    out += "\(index + 1)\n"
    out += timestamp(segment.startMs, style: .srt)
    out += " --> "
    out += timestamp(segment.endMs, style: .srt)
    out += "\n"
    out += sanitize(segment.text)
}
```

**Expected gain:** roughly **2-3x faster** on large transcripts and one allocation instead of *n*+1.

---

### P-08 — Multi-gigabyte file copy on the main thread (High)

**Bottleneck:** `FileImporterView.swift:26-62`

`FileImportCoordinator` is `@MainActor`, and `importFile` calls `FileManager.default.copyItem` directly. Importing a 2 GB video blocks the main thread for the entire copy. Past roughly 20 seconds the iOS watchdog terminates the app with `0x8badf00d` — which users experience as "the app crashes on big files".

**Optimized:** the copy moves to a detached task; only the UI state stays on the main actor. Note the security scope must be opened and closed *around* the copy, so the handshake goes inside the detached task rather than being closed before it starts:

```swift
try await Task.detached(priority: .userInitiated) {
    guard sourceURL.startAccessingSecurityScopedResource() else { throw FileImportError.accessDenied }
    defer { sourceURL.stopAccessingSecurityScopedResource() }

    let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey])
    if let size = values?.fileSize, Int64(size) > limit {
        throw FileImportError.tooLarge(bytes: Int64(size), limit: limit)
    }
    do {
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: destination.path)
    } catch {
        try? FileManager.default.removeItem(at: destination)   // no truncated copies left behind
        throw FileImportError.copyFailed(error)
    }
}.value
```

**Expected gain:** main thread never blocks on I/O; watchdog termination on large imports is eliminated; the UI can show copy progress.

---

### M-11 — Strong reference cycle in `URLImportCoordinator` (retain cycle)

**Bottleneck:** `MediaURLImportView.swift:43-65`

```swift
// ORIGINAL
activeTask = Task {                          // ← no capture list
    for try await update in stream {
        state = .downloading(progress: progress)   // implicit strong `self`
    }
}
```

`self` → `activeTask` → closure → `self`. A textbook cycle. It resolves when the task completes — except the loop has no exit on the `.failed` branch (line 58-59 sets state and keeps iterating), so a stream that stalls holds the cycle open indefinitely and the coordinator is never deallocated.

**Optimized:** `[weak self]` capture, terminal-state `return`, `activeTask = nil` on completion, and `deinit { activeTask?.cancel() }`.

**Expected gain:** eliminates a leak of the coordinator and everything it retains — including the `URLStreamDownloader` actor and its `URLSession`. A `URLSession` you never invalidate leaks its delegate and its connection pool.

---

### C-04 — The Cancel button does not cancel the download (Battery / data)

**Bottleneck:** `MediaURLImportView.swift:68-71` + `URLStreamDownloader.swift:65-76`

```swift
func cancel() {
    activeTask?.cancel()      // cancels the Swift Task only
    state = .idle
}
```

The `AsyncThrowingStream` has no `onTermination` handler, so nothing propagates to the `URLSessionDownloadTask`. Cancelling the consuming Task tears down the stream and leaves the transfer running to completion — continuing to burn cellular data and battery on a download the user explicitly stopped. When it finishes, its file is written to disk with no consumer and no scrub path: an **orphaned plaintext media file**, which is also a privacy finding.

The dictionary entry in `continuations` is likewise never removed, so every cancelled download leaks one continuation for the lifetime of the actor.

**Optimized:**

```swift
continuation.onTermination = { [weak self] _ in
    Task { await self?.retire(taskID: id, cancelTransfer: true) }
}
```

with `retire` removing the entry and calling `task.cancel()`.

**Expected gain:** cancellation actually stops the radio. On a large download over cellular this is the difference between a few hundred kilobytes and a few hundred megabytes of the user's data plan — and it closes the orphaned-file path.

---

### C-02 — The "mandatory" scrub is not guaranteed

**Bottleneck:** `ContentView.swift:48-50`

```swift
// ORIGINAL
defer {
    Task { await self.audioPipeline.scrub(sourceURL: media.sandboxURL, temporaryWAVURL: wavURL) }
}
```

`defer` fires on scope exit and spawns an *unstructured* Task; `process()` returns immediately without waiting. If the app is suspended or killed in the window between the defer firing and the task running, the scrub never happens. There is no compensating sweep, so the media stays on disk forever.

The README calls this scrub "mandatory" and describes it as happening "the instant inference has consumed" the file. As written, it is best-effort.

**Optimized:** awaited inline on every exit path, moved earlier (right after decode, since nothing reads the file after that), plus `scrubOrphans()` on app foreground as the backstop for kills.

**Expected gain:** shortens the plaintext-on-disk window from *import → end of inference* (potentially many minutes) to *import → end of decode*, and makes cleanup survive process death.

---

### B-02 — GPU/ANE acceleration is requested but not compiled in (Critical, battery + speed)

**Bottleneck:** cross-file — `CoreAIBridge.mm:54, 160` vs. `ThirdParty/Package.swift` vs. `scripts/fix-thirdparty-submodules.sh`

The bridge asks for hardware acceleration:

```cpp
cparams.use_gpu = true;              // CoreAIBridge.mm:54  — Core ML / Metal encoder
mparams.n_gpu_layers = 999;          // CoreAIBridge.mm:160 — "offload as much as Metal allows"
```

The build does not provide it. In `ThirdParty/Package.swift`, **both** targets exclude `ggml/src/ggml-metal`, the whisper target additionally excludes `src/coreml`, and both define `GGML_USE_CPU=1`. The whisper target also defines `GGML_NO_ACCELERATE=1`, ruling out even the Accelerate/BLAS CPU path. And `scripts/fix-thirdparty-submodules.sh` physically `rm -rf`s `ggml-metal` from both submodules before the build runs.

So this is a scalar CPU-only ggml build being asked for Metal offload and a Core ML encoder that are not linked in. Neither request fails loudly — ggml logs a warning and falls back.

The README compounds it: step 3 of "Vendoring the native engines" instructs the reader to `enable WHISPER_COREML=1`, which directly contradicts the `Package.swift` checked in beside it.

**Risk:** transcription runs at a small fraction of achievable speed, with the CPU pinned at 100% for the duration. On a phone that means sustained thermal throttling, severe battery drain, and — for a long file — a realistic chance of the watchdog or jetsam intervening before the job finishes.

**Optimized:** make the code tell the truth about the build, so the mismatch cannot hide:

```cpp
#ifndef COREAI_HAVE_METAL
#define COREAI_HAVE_METAL 0
#endif
#ifndef COREAI_HAVE_COREML
#define COREAI_HAVE_COREML 0
#endif

cparams.use_gpu     = (COREAI_HAVE_METAL || COREAI_HAVE_COREML) ? true : false;
mparams.n_gpu_layers = COREAI_HAVE_METAL ? 999 : 0;
```

**Expected gain:** none by itself — this makes the current state honest rather than faster. **The actual fix is a build decision, and it is the highest-leverage change available in this codebase.** Stop excluding `ggml-metal`, define `COREAI_HAVE_METAL=1`, and resolve the duplicate-`default.metallib` problem the exclusion was working around (build the two engines as separate SwiftPM targets with distinct metallib names, which the README already recommends for the `ggml.h` symbol collision). Metal offload on Apple silicon is typically a **5-20x** improvement for llama.cpp inference; the Core ML encoder path for whisper is comparable. Everything else in this report is a rounding error next to it.

Related: `n_threads` was hardcoded to `4` in both engines. On a device with two performance cores that oversubscribes by 2x, causing scheduler contention and heat with no throughput gain. Now derived from `hw.perflevel0.logicalcpu` via `sysctlbyname`.

---

### C-05 — Blocking C++ calls occupy cooperative-pool threads

**Bottleneck:** `AIInferenceManager.swift:94-159`

`transcribe` and `summarize` are `actor` methods that call straight into `whisper_full` and `llama_decode` — blocking C functions that run for minutes. Swift's cooperative thread pool sizes itself to the core count and assumes tasks yield. A task that blocks for minutes holds one of those threads for the duration, starving unrelated concurrency.

**Optimized:** bridged onto a dedicated serial `DispatchQueue` via `withCheckedThrowingContinuation`:

```swift
private let nativeQueue = DispatchQueue(label: "...native", qos: .userInitiated)

private func runOnNativeQueue<T: Sendable>(_ body: @Sendable @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        nativeQueue.async {
            do { continuation.resume(returning: try body()) }
            catch { continuation.resume(throwing: error) }
        }
    }
}
```

**Expected gain:** the cooperative pool stays available during inference, so downloads, UI updates, and SwiftData work are not starved. The actor still serialises access, so the "never both engines resident" invariant is preserved.

**P-11, related:** the 200 ms inter-engine `Task.sleep` is described as giving the OS time to reclaim whisper's pages. Sleeping does not free anything — it only gives already-released pages time to be reclaimed. The largest allocation in the process is the `samples` array (4 bytes per 16 kHz sample), and the original held it alive across the llama model load, so peak RSS was *whisper-freed + samples + llama-loading*. The patched `ContentView` releases it explicitly before summarisation begins. The sleep is kept — it is genuinely useful — but it is now backed by an actual release.

---

### Other correctness issues fixed in the patched files

| ID | Issue | File |
|---|---|---|
| R-06 | `Int(ms.rounded())` **traps at runtime** on NaN/∞ timestamps from whisper → crash on export. Now clamped. | `SubtitleFormatter.swift:56` |
| R-07 | Segment text containing `-->` or a newline corrupts SRT/VTT cue structure. Now sanitised. | `SubtitleFormatter.swift` |
| R-03 | `fatalError` on store-init failure = permanent crash-on-launch with no user recovery. Now falls back to in-memory *and tells the user*. | `PersistenceController.swift:55` |
| R-04 | `.summarizing` stage existed in the enum and the UI but was never assigned — the screen said "Transcribing" throughout summarisation. | `ContentView.swift` |
| R-05 | **Entitlement never enforced.** `isPremiumUser` only controlled the Upgrade button's visibility; the paywall advertises "unlimited file length & imports" against no check anywhere. | `ContentView.swift`, `StoreManager.swift` |
| R-09 | **No Restore Purchases** — App Review guideline 3.1.1 requires one for a non-consumable. Likely rejection. Added `restorePurchases()` via `AppStore.sync()`. | `StoreManager.swift` |
| R-12 | Price hardcoded as `"Unlock Lifetime — $9.99"`. Wrong in every non-USD storefront; common rejection. Use `product.displayPrice`. | `PaywallView.swift:44` |
| R-13 | Purchase button enabled before the product finished loading — an early tap surfaced `productNotFound` as a failure for what is a not-ready state. Also, a deliberate `userCancelled` was rendered as a red error. | `PaywallView.swift` |
| R-14 | No Terms / Privacy links on the purchase screen. Increasingly expected by reviewers on any paid surface. | `PaywallView.swift` |
| R-10 | Unverified transactions never finished → StoreKit redelivers them on every launch forever. | `StoreManager.swift` |
| M-14 | `Task.detached { guard let self else { continue } }` never terminates after deallocation. `continue` → `return`. | `StoreManager.swift:99` |
| M-05..M-10 | C-layer: null `strdup` reaching `String(cString:)`; `calloc(0)` misreported as OOM; negative `n_segments` cast to `size_t`; per-context `llama_backend_init`/`free`; ignored negative `llama_token_to_piece`; temp sampler made inert by a greedy sampler added after it. | `CoreAIBridge.mm` |
| — | `README.md` still contains **unresolved git conflict markers** (`<<<<<<< HEAD` at line 1, `>>>>>>>` at line 94). | `README.md` |
| — | `FileHandle.write(_:)` and `seek(toFileOffset:)` raise uncatchable Obj-C exceptions on failure (e.g. disk full). Moot now that the WAV writer is removed, but note it for any future use: prefer `try write(contentsOf:)`. | `AudioPipeline.swift` |

---

## CI/CD Pipeline Findings

The release pipeline handles your Apple Distribution private key. It deserves the same scrutiny as the app.

| ID | Finding | Line |
|---|---|---|
| **CI-01** | `KEYCHAIN_PASSWORD: ${{ github.run_id }}` — the run ID is **not a secret**. It is in the URL of every workflow run and in the public API. The keychain holding your distribution private key is protected by a publicly known value. Fix: `openssl rand -base64 32` + `::add-mask::`. | 140 |
| **CI-02** | `openssl pkcs12 ... -nocerts` **decrypts the signing private key into a shell pipe** for a diagnostic `grep -c`. And `-passin pass:"$P12_PASSWORD"` puts the passphrase in the process argument list, readable via `ps` by any concurrent process. Fix: delete the diagnostic (`security import` already fails loudly on a key-less .p12); if kept, use `-passin env:P12_PASSWORD`. | 180-186 |
| **CI-03** | `security import ... -A` grants **every application on the machine** unprompted access to the private key. The `-T /usr/bin/codesign -T /usr/bin/security` flags already grant exactly what is needed. Drop `-A`. | 190 |
| **CI-04** | `actions/checkout@v7`, `actions/upload-artifact@v6` — mutable tags. Whoever controls those repos can re-point the tag, and this job hands the action's process every signing secret it holds. Pin to commit SHAs. (Also verify those major versions exist; v7/v6 are ahead of what I have on record, so confirm before relying on them.) | 25, 302, 364 |
| **CI-05** | No `permissions:` block → the job inherits the repository default `GITHUB_TOKEN` scope, which on older repos is read/write across contents, packages and issues. Add `permissions: contents: read` and `persist-credentials: false`. | — |
| **CI-06** | The signing keychain is **never deleted** and `security list-keychain -d user -s` **replaces** the user search list rather than appending. Fine on ephemeral GitHub-hosted runners; on a self-hosted runner the distribution certificate and private key persist after the job. Add an `if: always()` cleanup that restores the list and runs `security delete-keychain`. | 193 |

Patched workflow (signing steps): `patched/ci/ios-build.yml`.

---

## 📱 Final Production-Ready Code

Your brief asked for "the complete, combined file". This is a multi-file project — 15 Swift sources plus the Obj-C++ bridge — so a single combined file would not compile or be usable. I've instead produced **drop-in replacements for each file that changed**, each carrying inline `S-xx` / `M-xx` / `P-xx` markers tying every edit back to a finding above.

```
patched/
├── Audio/AudioPipeline.swift              S-04 S-05 S-06 · M-01 M-02 M-03 · P-01 P-02 · R-01
├── Networking/
│   ├── URLStreamDownloader.swift          S-07 S-08 S-09 S-10 · M-04 · C-01 · B-01
│   └── SandboxPaths.swift                 S-05 S-11 S-16 · P-03 · R-02
├── Persistence/PersistenceController.swift  S-01 S-02 · R-03
├── CoreAI/
│   ├── CoreAIBridge.mm                    S-12 S-13 · M-05…M-10 · P-04 P-05 · B-02
│   └── AIInferenceManager.swift           C-05 · P-10 P-11 · R-04 R-08
├── Views/
│   ├── ContentView.swift                  C-02 · P-06 P-07 · R-04 R-05
│   ├── FileImporterView.swift             S-14 S-15 · P-08 · C-03
│   ├── MediaURLImportView.swift           S-16 · M-11 M-12 M-13 · C-04 · C-03
│   └── PaywallView.swift                  R-09 R-12 R-13 R-14
├── Export/SubtitleFormatter.swift         R-06 R-07 · P-09
├── Billing/StoreManager.swift             R-09 R-10 R-11 R-12 · M-14 M-15
├── ci/ios-build.yml                       CI-01…CI-06
└── gitignore.patched                      S-17   (rename to .gitignore)
```

**Unchanged and correct, no patch needed:** `OffGridApp.swift`, `TranscriptionModels.swift`, `LanguageOption.swift`, `IngestedMedia.swift`, `TextFileDocument.swift`, `CoreAIBridge.h`, `OffGrid-Bridging-Header.h`, `Info.plist.excerpt.xml`.

### Integration notes

Three patches change call signatures, so they must land together:

1. **`AudioPipeline.extractPCM` now returns `[Float]`**, not `(samples:temporaryWAVURL:)` — the WAV is gone (S-04). `scrub(sourceURL:)` loses its `temporaryWAVURL:` parameter. `ContentView` is already updated to match.
2. **`AIInferenceManager.process` gains `onPhaseChange:`** with a default value, so existing call sites still compile; `ContentView` passes a closure to drive the `.summarizing` state (R-04).
3. **`TranscriptionViewModel.process` gains `isPremium:`** for entitlement enforcement (R-05). Adjust the free-tier limit — `freeTierDurationLimit`, currently 10 minutes — to whatever your business model actually intends. I picked a value; you should pick the right one.

`FileImporterView` and `MediaURLImportView` migrate from `ObservableObject`/`@StateObject` to `@Observable`/`@State` (C-03), matching the rest of the app. No call-site changes.

### Suggested order of work

1. **B-02 first.** Decide whether this ships with Metal/Core ML. Everything about the app's performance, battery, and thermal behaviour depends on that one build decision, and it may change how you scope the rest.
2. **S-01, S-05, S-02** — the at-rest protection gaps. Small, self-contained, and they're the difference between the privacy claims being true and being aspirational.
3. **M-01, M-02, S-12** — the memory and crash chain from imported media through to the C++ layer.
4. **CI-01/02/03** — rotate the P12 passphrase while you're in there, and run the `.p8` history check from S-17.
5. **P-06, P-08** — the two main-thread stalls.
6. **R-09, R-12** — before your next App Store submission, or expect a rejection.

### What I could not verify

- **No build validation was possible.** No macOS toolchain, no Xcode, and `ThirdParty/whisper.cpp` and `ThirdParty/llama.cpp` are empty submodule directories in this archive. The patched files are reviewed for correctness but **have not been compiled**. Budget a build-and-fix pass.

  I did run a manual cross-file consistency pass over the patch set, which caught three defects in my own first draft — worth listing so you know the failure modes to look for when you do compile:
  1. `URLStreamDownloader` implemented a `URLSessionDataDelegate` method on a `URLSessionDownloadDelegate`, so the S-08/S-09 checks were unreachable (see the note under S-08).
  2. `AIInferenceManager.process`'s `onPhaseChange` was declared `@Sendable` but every realistic call site mutates `@MainActor` state inside it. Now `@MainActor @Sendable`, called with a direct `await`.
  3. `download(from:)` was marked `nonisolated` while the call site still wrote `await downloader.download(...)`, which is a spurious-`await` warning and a confusing witness for an `Actor`-constrained protocol. Now a plain actor method.

  Assume there are more of this kind. The concurrency annotations are where I'd expect the remaining ones to be.
- **llama.cpp API signatures drift between releases** — your own README flags this at step 5. I wrote against the same API generation the original targets (`llama_model_load_from_file`, `llama_init_from_model`, `llama_sampler_chain_*`, `llama_memory_clear`). Pin against whichever commit you actually vendor; `llama_memory_clear`/`llama_get_memory` in particular replaced an older `llama_kv_cache_clear` and the names may have moved again.
- **No git history** in the archive, so the S-17 `.p8` question is open. Please run those two `git log` commands against the real repo.
- **StoreKit behaviour is untested** — no sandbox account, no StoreKit configuration file present in the project.

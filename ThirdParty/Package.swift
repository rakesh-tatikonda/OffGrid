// swift-tools-version:5.10
// Save as: ThirdParty/Package.swift (a local package one level above
// the two submodules), then in Xcode: File > Add Package Dependencies >
// Add Local... > point at this folder. Add both WhisperEngine and
// LlamaEngine as linked libraries on your OffGrid app target.
//
// WHY TWO SEPARATE DYNAMIC LIBRARIES (not two static targets, not one
// merged target): whisper.cpp and llama.cpp each vendor their own copy
// of ggml.c, which defines the same global C symbols (ggml_new_tensor,
// ggml_free, etc). If both end up as *static* libraries linked into one
// binary, the linker sees the same symbol defined twice -> "duplicate
// symbol" error. Dynamic frameworks each keep their own private symbol
// table (Apple's two-level namespace), so both can define the same
// symbol names without colliding. That's what the README's "link as
// separate targets" note is getting at.
//
// CAVEAT: exact source paths below (ggml/src, src, include) match
// roughly-current whisper.cpp/llama.cpp layouts as of early-2026
// mainline, same as the bridge header in the README — both repos
// reshuffle directories across releases, so check your actual vendored
// commit's tree and adjust `sources:`/`publicHeadersPath:` to match
// before this will build.
//
// METAL SHADER FIX: ggml-metal.metal must NOT be swept up by the plain
// `sources:` glob. When SwiftPM/Xcode treats a .metal file as an
// ordinary compiled source (rather than an explicitly declared
// resource), it compiles it to a library named literally
// "default.metallib" and writes that straight into the shared
// Build Products directory instead of a per-target resource bundle.
// Since BOTH WhisperEngine and LlamaEngine vendor their own copy of
// ggml-metal.metal, that produced two build tasks writing the exact
// same output path -> "duplicate output file ... default.metallib"
// and the build failed outright. Declaring the .metal file as an
// explicit `resources: [.process(...)]` entry (and excluding it from
// `sources:`) makes SwiftPM build each target's Metal library into its
// own private resource bundle instead -- which is also exactly the
// pattern upstream ggml's own Package.swift uses, and which
// ggml-metal.m already knows how to find at runtime via its
// SWIFT_PACKAGE / SWIFTPM_MODULE_BUNDLE lookup path.
//
// REQUIRED SETUP STEP: after `git submodule update --init --recursive`,
// run `./scripts/fix-thirdparty-submodules.sh` once before opening Xcode
// or running xcodebuild (locally or in CI). Without it, resolution fails
// with "library product 'WhisperEngine'/'LlamaEngine' should not contain
// executable targets" -- see that script for the full explanation.

import PackageDescription

let package = Package(
    name: "OffGridNativeEngines",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "WhisperEngine", type: .dynamic, targets: ["WhisperEngine"]),
        .library(name: "LlamaEngine", type: .dynamic, targets: ["LlamaEngine"]),
    ],
    targets: [
        .target(
            name: "WhisperEngine",
            path: "whisper.cpp",
            // NOTE: ggml/src contains a subfolder per hardware backend
            // (CUDA, Vulkan, SYCL, HIP, ROCm/MUSA, OpenCL, CANN, etc).
            // Upstream's CMake build only ever compiles ggml-cpu
            // unconditionally and adds the rest behind explicit
            // GGML_<BACKEND> flags -- but a plain `sources: ["ggml/src"]`
            // glob has no such gating, so SwiftPM will try to compile
            // every one of these, and fail hard the moment it hits code
            // that needs the CUDA toolkit / Vulkan SDK / oneAPI / ROCm,
            // none of which exist on a normal Mac. We only want the CPU
            // backend plus Metal + BLAS (Accelerate), matching the
            // frameworks linked below, so the rest are excluded here.
            //
            // whisper.cpp's vendored ggml does not currently ship a
            // ggml-et backend (that's llama.cpp-specific as of this
            // writing) -- if a future sync adds one here too, add
            // "ggml/src/ggml-et" to this list, matching LlamaEngine.
            exclude: [
                "tests", "examples", "models", "bindings", "CMakeLists.txt",
                "src/openvino",
                "ggml/src/ggml-cann", "ggml/src/ggml-cuda", "ggml/src/ggml-hexagon",
                "ggml/src/ggml-hip", "ggml/src/ggml-musa", "ggml/src/ggml-opencl",
                "ggml/src/ggml-openvino", "ggml/src/ggml-rpc", "ggml/src/ggml-sycl",
                "ggml/src/ggml-virtgpu", "ggml/src/ggml-vulkan", "ggml/src/ggml-webgpu",
                "ggml/src/ggml-zdnn", "ggml/src/ggml-zendnn",
                // Metal shader source: built as a resource instead (see below),
                // not as a plain compiled source -- keep it out of `sources:`.
                "ggml/src/ggml-metal/ggml-metal.metal",
            ],
            sources: ["ggml/src", "src"],
            resources: [
                .process("ggml/src/ggml-metal/ggml-metal.metal"),
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("WHISPER_COREML", to: "1"),
                .unsafeFlags(["-O3"]),
            ],
            cxxSettings: [
                .define("WHISPER_COREML", to: "1"),
            ],
            linkerSettings: [
                .linkedFramework("CoreML"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .target(
            name: "LlamaEngine",
            path: "llama.cpp",
            // See the matching note on WhisperEngine above -- same fix,
            // same reason (unwanted hardware backends under ggml/src).
            //
            // ggml-et is llama.cpp-specific: an embedded/bare-metal
            // kernel backend that ships its own build tooling (shell
            // scripts under et-kernels/scripts and et-kernels/src, plus
            // a raw linker script, linker.ld). None of that is source
            // SwiftPM/Xcode knows how to compile, so if this exclusion
            // is ever missing or mistyped, the build fails with
            // "no rule to process file ... of type 'file'" for each of
            // those loose files. Keep this entry in place.
            exclude: [
                "tests", "examples", "models", "CMakeLists.txt",
                "ggml/src/ggml-cann", "ggml/src/ggml-cuda", "ggml/src/ggml-et",
                "ggml/src/ggml-hexagon", "ggml/src/ggml-hip", "ggml/src/ggml-musa",
                "ggml/src/ggml-opencl", "ggml/src/ggml-openvino", "ggml/src/ggml-rpc",
                "ggml/src/ggml-sycl", "ggml/src/ggml-virtgpu", "ggml/src/ggml-vulkan",
                "ggml/src/ggml-webgpu", "ggml/src/ggml-zdnn", "ggml/src/ggml-zendnn",
                // Metal shader source: built as a resource instead (see below),
                // not as a plain compiled source -- keep it out of `sources:`.
                "ggml/src/ggml-metal/ggml-metal.metal",
            ],
            sources: ["ggml/src", "src"],
            resources: [
                .process("ggml/src/ggml-metal/ggml-metal.metal"),
            ],
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-O3"]),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
    ],
    cLanguageStandard: .c17,
    cxxLanguageStandard: .cxx17
)

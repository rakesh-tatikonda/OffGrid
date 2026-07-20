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
            exclude: [
        "tests", "examples", "models", "bindings", "CMakeLists.txt",
        "src/openvino",
        "ggml/src/ggml-cann", "ggml/src/ggml-cuda", "ggml/src/ggml-hexagon",
        "ggml/src/ggml-hip", "ggml/src/ggml-musa", "ggml/src/ggml-opencl",
        "ggml/src/ggml-openvino", "ggml/src/ggml-rpc", "ggml/src/ggml-sycl",
        "ggml/src/ggml-virtgpu", "ggml/src/ggml-vulkan", "ggml/src/ggml-webgpu",
        "ggml/src/ggml-zdnn", "ggml/src/ggml-zendnn",
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
           exclude: [
        "tests", "examples", "models", "bindings", "CMakeLists.txt",
        "src/openvino",
        "ggml/src/ggml-cann", "ggml/src/ggml-cuda", "ggml/src/ggml-hexagon",
        "ggml/src/ggml-hip", "ggml/src/ggml-musa", "ggml/src/ggml-opencl",
        "ggml/src/ggml-openvino", "ggml/src/ggml-rpc", "ggml/src/ggml-sycl",
        "ggml/src/ggml-virtgpu", "ggml/src/ggml-vulkan", "ggml/src/ggml-webgpu",
        "ggml/src/ggml-zdnn", "ggml/src/ggml-zendnn",
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

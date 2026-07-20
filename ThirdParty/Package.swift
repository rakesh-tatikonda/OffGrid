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
            exclude: ["tests", "examples", "models", "bindings", "CMakeLists.txt"],
            sources: ["ggml/src", "src"],
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
            exclude: ["tests", "examples", "models", "CMakeLists.txt"],
            sources: ["ggml/src", "src"],
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

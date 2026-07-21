// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OffGridNativeEngines",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "WhisperEngine", targets: ["WhisperEngine"]),
        .library(name: "LlamaEngine", targets: ["LlamaEngine"])
    ],
    targets: [
        .target(
            name: "WhisperEngine",
            path: "whisper.cpp",
            exclude: [
                // Unsupported hardware backends for iOS
                "ggml/src/ggml-cpu/spacemit",
                "ggml/src/ggml-cuda",
                "ggml/src/ggml-sycl",
                "ggml/src/ggml-vulkan",
                "ggml/src/ggml-kompute",
                "ggml/src/ggml-rpc",
                "ggml/src/ggml-musa",
                "ggml/src/ggml-cann",
                "ggml/src/ggml-opencl",
                // Ignore test files, examples, and CLI tools
                "tests",
                "examples",
                "bindings",
                "extra",
                "models",
                "scripts"
            ],
            sources: [
                "ggml/src",
                "src"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("GGML_USE_CPU", to: "1"),
                .define("GGML_NO_ACCELERATE", to: "1") 
            ],
            cxxSettings: [
                .define("GGML_USE_CPU", to: "1"),
                .headerSearchPath("ggml/src"),
                .headerSearchPath("ggml/include")
            ]
        ),
        .target(
            name: "LlamaEngine",
            path: "llama.cpp",
            exclude: [
                // Unsupported hardware backends for iOS
                "ggml/src/ggml-cpu/spacemit",
                "ggml/src/ggml-cuda",
                "ggml/src/ggml-sycl",
                "ggml/src/ggml-vulkan",
                "ggml/src/ggml-kompute",
                "ggml/src/ggml-rpc",
                "ggml/src/ggml-musa",
                "ggml/src/ggml-cann",
                "ggml/src/ggml-opencl",
                // Ignore test files, examples, and CLI tools
                "tests",
                "examples",
                "bindings",
                "docs",
                "media",
                "models",
                "pocs",
                "prompts",
                "scripts"
            ],
            sources: [
                "ggml/src",
                "src"
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .define("GGML_USE_CPU", to: "1"),
                .headerSearchPath("ggml/src"),
                .headerSearchPath("ggml/include")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)

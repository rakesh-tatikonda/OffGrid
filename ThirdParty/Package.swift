// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OffGridNativeEngines",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "WhisperEngine", type: .dynamic, targets: ["WhisperEngine"]),
        .library(name: "LlamaEngine", type: .dynamic, targets: ["LlamaEngine"])
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
                "ggml/src/ggml-rpc",
                "ggml/src/ggml-musa",
                "ggml/src/ggml-cann",
                "ggml/src/ggml-opencl",
                // CPU arch folders for other CPUs
                "ggml/src/ggml-cpu/arch/x86",
                "ggml/src/ggml-cpu/arch/powerpc",
                "ggml/src/ggml-cpu/arch/riscv",
                "ggml/src/ggml-cpu/arch/s390",
                "ggml/src/ggml-cpu/arch/loongarch",
                "ggml/src/ggml-cpu/arch/wasm",
                // KleidiAI backend
                "ggml/src/ggml-cpu/kleidiai",
                // CoreML and OpenVINO acceleration backends
                "src/coreml",
                "src/openvino",
                // Ignore test files, examples, and CLI tools (only excluding folders that actually exist)
                "tests",
                "examples",
                "extra",
                "models",
                "scripts",
                // Exclude the CLI main file entry points so SwiftPM doesn't treat it as an executable
                "src/main.cpp",
                "src/whisper-cli.cpp",
                "common"
            ],
            sources: [
                "ggml/src",
                "src"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("GGML_USE_CPU", to: "1"),
                .define("GGML_NO_ACCELERATE", to: "1"),
                .headerSearchPath("ggml/src"),
                .headerSearchPath("ggml/include"),
                .headerSearchPath("ggml/src/ggml-cpu")
            ],
            cxxSettings: [
                .define("GGML_USE_CPU", to: "1"),
                .define("WHISPER_VERSION", to: "\"1.9.0\""),
                .define("PARAKEET_VERSION", to: "\"1.9.0\""),
                .headerSearchPath("ggml/src"),
                .headerSearchPath("ggml/include"),
                .headerSearchPath("ggml/src/ggml-cpu")
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
                "ggml/src/ggml-rpc",
                "ggml/src/ggml-musa",
                "ggml/src/ggml-cann",
                "ggml/src/ggml-opencl",
                // CPU arch folders for other CPUs
                "ggml/src/ggml-cpu/arch/x86",
                "ggml/src/ggml-cpu/arch/powerpc",
                "ggml/src/ggml-cpu/arch/riscv",
                "ggml/src/ggml-cpu/arch/s390",
                "ggml/src/ggml-cpu/arch/loongarch",
                "ggml/src/ggml-cpu/arch/wasm",
                // KleidiAI backend
                "ggml/src/ggml-cpu/kleidiai",
                // Ignore test files, examples, and CLI tools (only excluding folders that actually exist)
                "tests",
                "examples",
                "docs",
                "media",
                "models",
                "pocs",
                "scripts",
                // Exclude the CLI main file entry points so SwiftPM doesn't treat it as an executable
                "src/llama-cli.cpp",
                "src/main.cpp",
                "common"
            ],
            sources: [
                "ggml/src",
                "src"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("GGML_USE_CPU", to: "1"),
                .headerSearchPath("ggml/src"),
                .headerSearchPath("ggml/include"),
                .headerSearchPath("ggml/src/ggml-cpu"),
                .headerSearchPath("src")
            ],
            cxxSettings: [
                .define("GGML_USE_CPU", to: "1"),
                .headerSearchPath("ggml/src"),
                .headerSearchPath("ggml/include"),
                .headerSearchPath("ggml/src/ggml-cpu"),
                .headerSearchPath("src")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)

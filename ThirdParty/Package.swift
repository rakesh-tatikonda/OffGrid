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
                // CPU arch folders for other CPUs. SwiftPM compiles every file
                // under `sources`, but only the arm64 folder is valid for this
                // target. CMake selects a single arch dir; we replicate that by
                // excluding all non-ARM ones (leaving ggml-cpu/arch/arm).
                "ggml/src/ggml-cpu/arch/x86",
                "ggml/src/ggml-cpu/arch/powerpc",
                "ggml/src/ggml-cpu/arch/riscv",
                "ggml/src/ggml-cpu/arch/s390",
                "ggml/src/ggml-cpu/arch/loongarch",
                "ggml/src/ggml-cpu/arch/wasm",
                // CoreML and OpenVINO are opt-in acceleration backends. The
                // default CPU build does not compile them (CMake gates them
                // behind WHISPER_COREML / WHISPER_OPENVINO). OpenVINO needs an
                // SDK that isn't present; CoreML needs the -DWHISPER_USE_COREML
                // path wired up. Exclude both so only the CPU path is built.
                "src/coreml",
                "src/openvino",
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
                .define("GGML_NO_ACCELERATE", to: "1"),
                .headerSearchPath("ggml/src"),
                .headerSearchPath("ggml/include"),
                .headerSearchPath("ggml/src/ggml-cpu")
            ],
            cxxSettings: [
                .define("GGML_USE_CPU", to: "1"),
                // Normally injected by CMake (project VERSION). whisper.cpp and
                // parakeet.cpp return these directly, so they must be defined.
                // Set to match the pinned whisper.cpp submodule if you care
                // about the reported version string.
                .define("WHISPER_VERSION", to: "\"1.9.1\""),
                .define("PARAKEET_VERSION", to: "\"1.9.1\""),
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
                "ggml/src/ggml-kompute",
                "ggml/src/ggml-rpc",
                "ggml/src/ggml-musa",
                "ggml/src/ggml-cann",
                "ggml/src/ggml-opencl",
                // CPU arch folders for other CPUs (see WhisperEngine note).
                // Keep only ggml-cpu/arch/arm for the arm64 target.
                "ggml/src/ggml-cpu/arch/x86",
                "ggml/src/ggml-cpu/arch/powerpc",
                "ggml/src/ggml-cpu/arch/riscv",
                "ggml/src/ggml-cpu/arch/s390",
                "ggml/src/ggml-cpu/arch/loongarch",
                "ggml/src/ggml-cpu/arch/wasm",
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
            cSettings: [
                .define("GGML_USE_CPU", to: "1"),
                .headerSearchPath("ggml/src"),
                .headerSearchPath("ggml/include"),
                .headerSearchPath("ggml/src/ggml-cpu")
            ],
            cxxSettings: [
                .define("GGML_USE_CPU", to: "1"),
                .headerSearchPath("ggml/src"),
                .headerSearchPath("ggml/include"),
                .headerSearchPath("ggml/src/ggml-cpu")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)

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
                "ggml/src/ggml-hexagon",
                // Metal GPU backend: excluded for this CPU-only build. Its .metal
                // shaders compile to default.metallib, which collides with the
                // LlamaEngine copy when both frameworks are embedded in one app.
                "ggml/src/ggml-metal",
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
                // Ignore non-source folders/files
                "tests",
                "examples",
                "models",
                "scripts",
                "CMakeLists.txt",
                "Makefile"
                // NOTE: whisper.cpp's CLI/stream sources with main() live under
                // examples/ (already excluded above), not src/, so no per-file
                // exclusions are needed here.
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
                "ggml/src/ggml-hexagon",
                // Metal GPU backend: excluded for this CPU-only build. Its .metal
                // shaders compile to default.metallib, which collides with the
                // WhisperEngine copy when both frameworks are embedded in one app.
                "ggml/src/ggml-metal",
                // CPU arch folders for other CPUs
                "ggml/src/ggml-cpu/arch/x86",
                "ggml/src/ggml-cpu/arch/powerpc",
                "ggml/src/ggml-cpu/arch/riscv",
                "ggml/src/ggml-cpu/arch/s390",
                "ggml/src/ggml-cpu/arch/loongarch",
                "ggml/src/ggml-cpu/arch/wasm",
                // KleidiAI backend
                "ggml/src/ggml-cpu/kleidiai",
                // Ignore non-source folders/files
                "tests",
                "examples",
                "docs",
                "media",
                "models",
                "pocs",
                "scripts",
                "CMakeLists.txt",
                "Makefile"
                // NOTE: llama.cpp's CLI/server sources with main() live under
                // tools/ and examples/ (outside the scanned src/ path), so no
                // per-file exclusions are needed here.
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

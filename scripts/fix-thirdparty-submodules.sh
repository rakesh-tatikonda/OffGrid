#!/bin/bash
set -e

echo "Running ThirdParty submodule fixes..."

# 1. Strip nested Package.swift files 
echo "Removing nested Package.swift files..."
rm -f ThirdParty/whisper.cpp/Package.swift
rm -f ThirdParty/llama.cpp/Package.swift

# 2. Strip CLI entry points
echo "Removing CLI executables to force Library targets..."
find ThirdParty/whisper.cpp -name "main.swift" -type f -delete
find ThirdParty/whisper.cpp -name "main.cpp" -type f -delete
find ThirdParty/whisper.cpp -name "main.c" -type f -delete

find ThirdParty/llama.cpp -name "main.swift" -type f -delete
find ThirdParty/llama.cpp -name "main.cpp" -type f -delete
find ThirdParty/llama.cpp -name "main.c" -type f -delete

# 3. Strip all unsupported/unused backends to fix Metal collision and SPM warnings
echo "Removing unused GGML backends (Metal, WebGPU, etc.)..."
BACKENDS_TO_REMOVE=(
    "ggml-metal"
    "ggml-metal.metal"
    "ggml-blas"
    "ggml-cpu/cmake"
    "ggml-cpu/spacemit"
    "ggml-et"
    "ggml-hexagon"
    "ggml-hip"
    "ggml-openvino"
    "ggml-virtgpu"
    "ggml-webgpu"
    "ggml-zdnn"
    "ggml-zendnn"
    "ggml-cuda"
    "ggml-sycl"
    "ggml-kompute"
    "ggml-rpc"
    "ggml-musa"
    "ggml-cann"
)

for backend in "${BACKENDS_TO_REMOVE[@]}"; do
    rm -rf "ThirdParty/whisper.cpp/ggml/src/$backend"
    rm -rf "ThirdParty/llama.cpp/ggml/src/$backend"
done

# 4. Clean up stray CMake files that cause "no rule to process" warnings
echo "Removing CMake scripts..."
find ThirdParty/whisper.cpp -name "CMakeLists.txt" -type f -delete
find ThirdParty/llama.cpp -name "CMakeLists.txt" -type f -delete

echo "ThirdParty submodule fixes applied successfully!"

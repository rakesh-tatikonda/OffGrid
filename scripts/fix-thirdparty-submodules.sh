#!/bin/bash
set -e

echo "Running ThirdParty submodule fixes..."

# 1. Strip nested Package.swift files 
# This prevents XcodeGen and SPM from getting confused by nested packages.
echo "Removing nested Package.swift files..."
rm -f ThirdParty/whisper.cpp/Package.swift
rm -f ThirdParty/llama.cpp/Package.swift

# 2. Strip CLI entry points
# Removes main.swift/main.cpp to prevent SPM from trying to build command-line executables for iOS.
echo "Removing CLI executables..."
find ThirdParty/whisper.cpp -name "main.swift" -type f -delete
find ThirdParty/llama.cpp -name "main.swift" -type f -delete

# 3. Remove unsupported GGML hardware backends
# This prevents clang from choking on RISC-V (spacemit), CUDA, or SYCL instructions during an iOS build.
echo "Removing unsupported GGML backends..."
BACKENDS_TO_REMOVE=(
    "ggml-cpu/spacemit"
    "ggml-cuda"
    "ggml-sycl"
    "ggml-vulkan"
    "ggml-kompute"
    "ggml-rpc"
    "ggml-musa"
    "ggml-cann"
)

for backend in "${BACKENDS_TO_REMOVE[@]}"; do
    # Clean whisper.cpp backends
    if [ -d "ThirdParty/whisper.cpp/ggml/src/$backend" ]; then
        rm -rf "ThirdParty/whisper.cpp/ggml/src/$backend"
        echo "Removed whisper.cpp backend: $backend"
    fi
    
    # Clean llama.cpp backends
    if [ -d "ThirdParty/llama.cpp/ggml/src/$backend" ]; then
        rm -rf "ThirdParty/llama.cpp/ggml/src/$backend"
        echo "Removed llama.cpp backend: $backend"
    fi
done

echo "ThirdParty submodule fixes applied successfully!"

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

# 5. Clean up external accelerator integrations inside the src/ folder
echo "Removing Intel OpenVINO integrations..."
rm -rf "ThirdParty/whisper.cpp/src/openvino"

# 6. Fix missing GGML version macros 
# Injects the missing definitions at the top of ggml.c so clang doesn't crash
echo "Patching missing GGML_VERSION and GGML_COMMIT macros..."
patch_ggml_c() {
    local file=$1
    if [ -f "$file" ]; then
        echo '#ifndef GGML_VERSION' > temp_ggml.c
        echo '#define GGML_VERSION "unknown"' >> temp_ggml.c
        echo '#endif' >> temp_ggml.c
        echo '#ifndef GGML_COMMIT' >> temp_ggml.c
        echo '#define GGML_COMMIT "unknown"' >> temp_ggml.c
        echo '#endif' >> temp_ggml.c
        
        cat "$file" >> temp_ggml.c
        mv temp_ggml.c "$file"
        echo "Patched $file"
    fi
}

patch_ggml_c "ThirdParty/whisper.cpp/ggml/src/ggml.c"
patch_ggml_c "ThirdParty/llama.cpp/ggml/src/ggml.c"

echo "ThirdParty submodule fixes applied successfully!"

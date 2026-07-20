#!/usr/bin/env bash
# Optional: sanity-check the vendored whisper.cpp / llama.cpp C++ core
# on Linux (CPU backend only) without Swift or Xcode, before pushing.
#
# WHAT THIS DOES: builds each engine with its own native CMake build
# (CPU backend only -- no CUDA/Vulkan/etc, no CoreML, no Metal), which
# is fully cross-platform. This is a REAL compile of the same
# ggml/whisper.cpp/llama.cpp sources CoreAIBridge.cpp links against, so
# it catches missing submodules or an API CoreAIBridge.cpp calls that
# got renamed in the commit you vendored -- all without a Mac.
#
# WHAT THIS DOES NOT DO: build the OffGrid app itself. SwiftUI, SwiftData,
# CoreML, and Metal only exist on Apple platforms, so the actual app can
# only be compiled on macOS -- locally in Xcode, or headlessly via
# .github/workflows/ios-build.yml on GitHub's macOS cloud runners
# (needs no Xcode on your machine, just `git push`).
#
# USAGE:
#   git submodule update --init --recursive
#   ./scripts/fix-thirdparty-submodules.sh
#   ./scripts/linux-sanity-build.sh
#
# Requires: cmake (>=3.14), a C++17 compiler, make.
#   Debian/Ubuntu: sudo apt-get install -y cmake build-essential

set -euo pipefail
cd "$(dirname "$0")/.."

JOBS="$(nproc 2>/dev/null || echo 4)"

build_engine () {
  local name="$1" dir="$2"
  shift 2
  echo "=================================================="
  echo "Building ${name} (${dir}) -- CPU backend only"
  echo "=================================================="
  if [ ! -f "${dir}/CMakeLists.txt" ]; then
    echo "ERROR: ${dir}/CMakeLists.txt not found."
    echo "Did you run 'git submodule update --init --recursive'?"
    exit 1
  fi
  cmake -S "${dir}" -B "${dir}/build-linux-sanity" \
    -DCMAKE_BUILD_TYPE=Release \
    "$@"
  cmake --build "${dir}/build-linux-sanity" -j "${JOBS}"
  echo "${name}: OK"
  echo
}

build_engine "whisper.cpp" "ThirdParty/whisper.cpp" \
  -DWHISPER_COREML=OFF \
  -DGGML_METAL=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF

build_engine "llama.cpp" "ThirdParty/llama.cpp" \
  -DGGML_METAL=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_SERVER=OFF

echo "Both engines compiled cleanly on this machine's CPU backend."
echo "This does NOT confirm the iOS app builds -- push to GitHub to run"
echo "the real Xcode build in .github/workflows/ios-build.yml for that."

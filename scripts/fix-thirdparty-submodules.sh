#!/usr/bin/env bash
# REQUIRED STEP -- run this once every time you (re)populate the
# ThirdParty submodules, BEFORE opening Xcode or running xcodebuild,
# whether locally or in CI:
#
#   git submodule update --init --recursive
#   ./scripts/fix-thirdparty-submodules.sh
#
# WHY THIS EXISTS:
# whisper.cpp and llama.cpp each vendor an example Swift app (e.g.
# examples/whisper.swiftui, examples/batched.swift) containing a file
# literally named main.swift. The moment SwiftPM's target-source walk
# encounters ANY file named exactly "main.swift" inside a target's
# directory tree that isn't blocked by `exclude:`, it force-classifies
# that whole target as executable -- which is what produces:
#
#   library product 'WhisperEngine' should not contain executable
#   targets (it has 'WhisperEngine')
#
# ThirdParty/Package.swift's `exclude: ["examples", ...]` entries are
# meant to block this, but whisper.cpp/llama.cpp reshuffle their
# directory layout across releases (their build-swift example, Swift
# bindings, demo apps, etc. have moved before and will again), so an
# exclude list tuned for one vendored commit can miss it on the next.
# Physically deleting every main.swift under the vendored trees sidesteps
# that fragility entirely -- it doesn't matter where upstream decides to
# put its demo app next time, since CoreAIBridge.cpp only needs the
# public C APIs (whisper_*, llama_*), never the demo Swift code.
#
# This is idempotent and safe to run as many times as you want.

set -euo pipefail
cd "$(dirname "$0")/.."

for dir in ThirdParty/whisper.cpp ThirdParty/llama.cpp; do
  if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "WARNING: ${dir} is missing or empty."
    echo "  Run 'git submodule update --init --recursive' first, then re-run this script."
    continue
  fi

  echo "Cleaning ${dir} ..."

  # Remove every main.swift anywhere in the tree (demo apps, wherever
  # upstream currently puts them).
  find "$dir" -name "main.swift" -print -delete

  # Remove any nested Package.swift shipped by upstream's own examples
  # (e.g. llama.cpp's examples/batched.swift/Package.swift). These
  # aren't needed to build the library targets and are harmless to
  # remove, but keeping them out avoids any ambiguity during resolution.
  find "$dir" -name "Package.swift" -print -delete

  # Remove build-system files that aren't source code. Because
  # ThirdParty/Package.swift declares `sources: ["ggml/src", "src"]`
  # explicitly, SwiftPM force-classifies EVERY non-header file under
  # those paths as a compile source (this is a real, separate SwiftPM
  # behavior from the main.swift issue above -- once `sources:` is
  # explicit, its automatic "is this actually compilable code" check is
  # skipped). Both repos vendor a CMakeLists.txt in nearly every
  # subfolder (their real build system, which we don't use at all -- we
  # build via SwiftPM/Xcode, never CMake) plus a couple of .cmake helper
  # modules under ggml-cpu/cmake. Left in place, Xcode tries to "compile"
  # them and fails with "no rule to process file ... for architecture
  # x86_64". None of these are needed for anything we do here.
  find "$dir" -name "CMakeLists.txt" -print -delete
  find "$dir" -name "*.cmake" -print -delete
done

echo "Done. Safe to open Xcode / run xcodebuild now."

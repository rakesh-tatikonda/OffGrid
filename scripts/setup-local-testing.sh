#!/usr/bin/env bash
#
# scripts/setup-local-testing.sh
#
# Gets OffGrid to a first launchable build with the smallest usable models.
# Run from the repo root. Safe to re-run.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODELS_DIR="OffGrid/Resources/Models"

echo "==> 1/4  Fetching native engine submodules"
# This is the step that was never run. Without it ThirdParty/whisper.cpp and
# ThirdParty/llama.cpp are empty, nothing native links, and the app dies in
# dyld before main().
git submodule update --init --recursive

for d in ThirdParty/whisper.cpp ThirdParty/llama.cpp; do
  if [ -z "$(ls -A "$d" 2>/dev/null)" ]; then
    echo "ERROR: $d is still empty. Check network/credentials and retry." >&2
    exit 1
  fi
  echo "    ok: $d ($(ls -A "$d" | wc -l | tr -d ' ') entries)"
done

echo "==> 2/4  Applying vendored-source fixups"
./scripts/fix-thirdparty-submodules.sh

echo "==> 3/4  Fetching models"
mkdir -p "$MODELS_DIR"

# --- Speech model -------------------------------------------------------
# tiny.en is ~75 MB vs ~500 MB for small. Noticeably worse transcripts, but
# this is about proving the pipeline runs, not about quality.
#
# IMPORTANT: the filename must match OffGridApp.swift exactly:
#     Bundle.main.path(forResource: "ggml-small-encoder", ofType: "bin")
# A mismatch returns "" and you get "model missing from this build".
WHISPER_DEST="$MODELS_DIR/ggml-small-encoder.bin"
WHISPER_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"

if [ -f "$WHISPER_DEST" ]; then
  echo "    skip: $WHISPER_DEST already present"
else
  echo "    downloading whisper tiny.en -> $WHISPER_DEST"
  curl -L --fail --progress-bar "$WHISPER_URL" -o "$WHISPER_DEST"
fi

# --- Text model ---------------------------------------------------------
# Set LLAMA_URL to a small instruct-tuned GGUF (Q4_K_M) before running, e.g. a
# 0.5B-1B parameter model at roughly 300-700 MB. gemma-2b-q4_k_m is ~1.5 GB,
# which is a lot to iterate against.
#
# I have deliberately not hardcoded a URL here: Hugging Face repo and file
# paths for quantised models change often enough that a stale one would fail
# confusingly. Pick a repo, copy the resolve/main/... link for the .gguf, and
# export it:
#
#     export LLAMA_URL="https://huggingface.co/<repo>/resolve/main/<file>.gguf"
#
# NOTE ON PROMPT FORMAT: CoreAIBridge.mm hardcodes Gemma's chat template
# (<start_of_turn>user … <end_of_turn><start_of_turn>model). A non-Gemma model
# will still run and produce output, but the summaries will be poor until you
# swap the template in coreai_llama_summarize to match your model.
LLAMA_DEST="$MODELS_DIR/gemma-2b-q4_k_m.gguf"

if [ -f "$LLAMA_DEST" ]; then
  echo "    skip: $LLAMA_DEST already present"
elif [ -n "${LLAMA_URL:-}" ]; then
  echo "    downloading text model -> $LLAMA_DEST"
  curl -L --fail --progress-bar "$LLAMA_URL" -o "$LLAMA_DEST"
else
  echo "    WARNING: LLAMA_URL not set, skipping text model."
  echo "             Transcription will work; summarization will fail with"
  echo "             'model missing from this build'. Set LLAMA_URL and re-run."
fi

echo "==> 4/4  Verifying"
ls -lh "$MODELS_DIR" || true

echo
echo "Done. Next:"
echo "  xcodegen generate"
echo "  open CapSureTranscribe.xcodeproj"
echo
echo "Build for a SIMULATOR target first — see the signing note in the chat."

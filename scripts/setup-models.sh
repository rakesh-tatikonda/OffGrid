#!/usr/bin/env bash
#
# scripts/setup-models.sh
#
# Fetches the native engine submodules and stages the on-device models.
# Run from the repo root. Safe to re-run — existing files are skipped.
#
#   MODE=testing    ./scripts/setup-models.sh     # ~0.5-0.8 GB, fast to iterate
#   MODE=production ./scripts/setup-models.sh     # ~2.0 GB, ships to users
#
# MODE defaults to testing. The text model URL is always supplied by you —
# see "TEXT MODEL" below for why it is not hardcoded.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${MODE:-testing}"
MODELS_DIR="OffGrid/Resources/Models"

case "$MODE" in
  testing|production) ;;
  *) echo "ERROR: MODE must be 'testing' or 'production' (got '$MODE')" >&2; exit 1 ;;
esac

echo "==> mode: $MODE"

# ---------------------------------------------------------------------------
# 1. Native engines
# ---------------------------------------------------------------------------
echo "==> 1/4  Fetching native engine submodules"
# Without this, ThirdParty/whisper.cpp and ThirdParty/llama.cpp are empty,
# nothing native compiles, and the app dies in dyld before main().
if [ ! -d .git ]; then
  echo "ERROR: no .git directory here." >&2
  echo "       If you unzipped this rather than cloning, git has no submodule" >&2
  echo "       state to act on. Clone the repository, or run 'git init' and" >&2
  echo "       re-add both submodules from .gitmodules first." >&2
  exit 1
fi

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

# ---------------------------------------------------------------------------
# 2. Models
# ---------------------------------------------------------------------------
echo "==> 3/4  Staging models"
mkdir -p "$MODELS_DIR"

# FILENAMES ARE LOAD-BEARING. OffGridApp.swift does:
#     Bundle.main.path(forResource: "ggml-small-encoder", ofType: "bin")
#     Bundle.main.path(forResource: "gemma-2b-q4_k_m",     ofType: "gguf")
# A mismatch returns "" and surfaces at runtime as "model missing from this
# build" (finding R-08), not as a build error. So whatever you download gets
# saved under these exact names.
WHISPER_DEST="$MODELS_DIR/ggml-small-encoder.bin"
LLAMA_DEST="$MODELS_DIR/gemma-2b-q4_k_m.gguf"

# --- SPEECH MODEL ----------------------------------------------------------
# ggerganov/whisper.cpp on Hugging Face is stable and ungated (MIT), so this
# one is safe to hardcode.
#   testing:    tiny.en  ~75 MB   — noticeably worse, but proves the pipeline
#   production: small    ~488 MB  — what the resource name implies
if [ "$MODE" = "production" ]; then
  WHISPER_URL="${WHISPER_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin}"
  WHISPER_MIN=400000000
else
  WHISPER_URL="${WHISPER_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin}"
  WHISPER_MIN=50000000
fi

# --- TEXT MODEL ------------------------------------------------------------
# Deliberately NOT hardcoded, for three reasons:
#
#  1. LICENSING. The original Gemma releases ship under Google's Gemma Terms
#     of Use, not Apache 2.0. Those terms carry use restrictions you must pass
#     through to your own users — which is a real question for a paid App
#     Store app, not a formality. Newer Gemma generations are Apache 2.0,
#     which is far simpler to redistribute commercially. Confirm the licence
#     on the exact model card you pull from before shipping.
#
#  2. GATING. Gated Hugging Face repos require accepting terms on the model
#     card and passing a token; an unauthenticated curl silently receives an
#     HTML page, which is why the size check below exists.
#
#  3. CHURN. Quantised-model repos and filenames move often enough that a
#     hardcoded URL would rot and fail confusingly.
#
# PROMPT FORMAT: CoreAIBridge.mm hardcodes Gemma's chat template
# (<start_of_turn>user … <end_of_turn><start_of_turn>model). Staying in the
# Gemma family keeps that valid. Anything else will run but summarise poorly
# until you swap the template in coreai_llama_summarize.
#
#   export LLAMA_URL="https://huggingface.co/<repo>/resolve/main/<file>.gguf"
#   export HF_TOKEN="hf_..."      # only if the repo is gated
#
LLAMA_MIN=200000000
[ "$MODE" = "production" ] && LLAMA_MIN=800000000

fetch() {
  local url="$1" dest="$2" min="$3" label="$4"

  if [ -f "$dest" ]; then
    echo "    skip: $dest already present ($(du -h "$dest" | cut -f1))"
    return 0
  fi

  echo "    downloading $label"
  # No arrays: macOS ships Bash 3.2, where "${arr[@]}" on an EMPTY array
  # under `set -u` aborts with "unbound variable". Safe only from 4.4.
  if [ -n "${HF_TOKEN:-}" ]; then
    curl -L --fail --progress-bar -H "Authorization: Bearer ${HF_TOKEN}" "$url" -o "$dest"
  else
    curl -L --fail --progress-bar "$url" -o "$dest"
  fi

  # A gated repo, an expired link, or a redirect stub all return a small
  # HTML body that would otherwise be archived as a "model" and only fail on
  # device. Catch it here.
  local size
  size=$(stat -f%z "$dest" 2>/dev/null || stat -c%s "$dest" 2>/dev/null || echo 0)
  if [ "$size" -lt "$min" ]; then
    echo "ERROR: $dest is only $size bytes (expected >= $min)." >&2
    echo "       The URL probably returned an error page. If the repo is" >&2
    echo "       gated, accept its terms on the model card and set HF_TOKEN." >&2
    rm -f "$dest"
    exit 1
  fi
}

fetch "$WHISPER_URL" "$WHISPER_DEST" "$WHISPER_MIN" "speech model"

if [ -n "${LLAMA_URL:-}" ]; then
  fetch "$LLAMA_URL" "$LLAMA_DEST" "$LLAMA_MIN" "text model"
elif [ -f "$LLAMA_DEST" ]; then
  echo "    skip: $LLAMA_DEST already present ($(du -h "$LLAMA_DEST" | cut -f1))"
elif [ "$MODE" = "production" ]; then
  echo "ERROR: LLAMA_URL is not set. A production build must ship the text" >&2
  echo "       model or summarization fails on every device." >&2
  exit 1
else
  echo "    WARNING: LLAMA_URL not set, skipping text model."
  echo "             Transcription will work end to end; summarization will"
  echo "             fail with 'model missing from this build'."
fi

# ---------------------------------------------------------------------------
# 3. Report
# ---------------------------------------------------------------------------
echo "==> 4/4  Result"
ls -lh "$MODELS_DIR"
echo
echo "    model payload: $(du -sh "$MODELS_DIR" | cut -f1)"
echo
echo "Expected final app size:"
echo "    linked but NOT embedded (broken) ~300 KB"
echo "    embedded, no models              ~20 MB"
echo "    embedded + testing models        ~0.5-0.8 GB"
echo "    embedded + production models     ~2.0 GB   (Apple's cap is 4 GB)"
echo
echo "Next:"
echo "    xcodegen generate"
echo "    open CapSureTranscribe.xcodeproj"
echo
echo "Then confirm target -> General -> 'Frameworks, Libraries, and Embedded"
echo "Content' shows BOTH products as 'Embed & Sign'. If they say 'Do Not"
echo "Embed', you get a ~300 KB app that crashes in dyld on launch."

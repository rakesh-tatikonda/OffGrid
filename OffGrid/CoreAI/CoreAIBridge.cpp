//
//  CoreAIBridge.cpp
//  OffGrid
//
//  Implementation of the C bridge declared in CoreAIBridge.h.
//
//  Vendoring note: this file expects whisper.cpp (with the Core ML /
//  Metal encoder enabled) and llama.cpp to be added to the Xcode project
//  as source packages (their own .h/.cpp/.mm files), NOT as system
//  libraries. Adjust the two #include paths below to match wherever you
//  vendor them (e.g. via `git submodule add` under ThirdParty/).
//
#include "CoreAIBridge.h"

#include "whisper.h"      // from whisper.cpp
#include "llama.h"        // from llama.cpp

#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Small internal helpers
// ---------------------------------------------------------------------------

static char *coreai_strdup(const std::string &s) {
    char *out = static_cast<char *>(std::malloc(s.size() + 1));
    if (!out) return nullptr;
    std::memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

static void set_error(CoreAITranscriptResult *result, const char *msg) {
    result->success = false;
    result->segments = nullptr;
    result->segment_count = 0;
    std::memset(result->detected_language, 0, sizeof(result->detected_language));
    std::strncpy(result->error_message, msg, sizeof(result->error_message) - 1);
    result->error_message[sizeof(result->error_message) - 1] = '\0';
}

// ---------------------------------------------------------------------------
// Engine 1: whisper.cpp
// ---------------------------------------------------------------------------

WhisperContextHandle coreai_whisper_init(const char *model_path) {
    if (!model_path) return nullptr;

    whisper_context_params cparams = whisper_context_default_params();
    // Route the encoder through Apple's Neural Engine via the Core ML
    // side-model whisper.cpp loads automatically when a matching
    // *.mlmodelc bundle sits next to the .bin/.gguf model on disk.
    cparams.use_gpu = true;

    struct whisper_context *ctx = whisper_init_from_file_with_params(model_path, cparams);
    return static_cast<WhisperContextHandle>(ctx);
}

CoreAITranscriptResult *coreai_whisper_transcribe(WhisperContextHandle handle,
                                                   const float *pcm_samples,
                                                   int64_t sample_count,
                                                   const char *language_code,
                                                   bool translate_to_english) {
    auto *result = static_cast<CoreAITranscriptResult *>(std::calloc(1, sizeof(CoreAITranscriptResult)));
    if (!result) return nullptr;

    auto *ctx = static_cast<struct whisper_context *>(handle);
    if (!ctx) {
        set_error(result, "whisper context is null — call coreai_whisper_init first");
        return result;
    }
    if (!pcm_samples || sample_count <= 0) {
        set_error(result, "empty PCM buffer passed to whisper");
        return result;
    }

    whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wparams.print_progress   = false;
    wparams.print_special    = false;
    wparams.print_realtime   = false;
    wparams.print_timestamps = false;
    wparams.translate        = translate_to_english;
    wparams.n_threads        = 4;
    wparams.token_timestamps = true;
    wparams.single_segment   = false;

    const bool auto_detect = (language_code == nullptr) ||
                              (std::strcmp(language_code, "auto") == 0);
    wparams.language        = auto_detect ? nullptr : language_code;
    wparams.detect_language = auto_detect;

    const int rc = whisper_full(ctx, wparams, pcm_samples, static_cast<int>(sample_count));
    if (rc != 0) {
        set_error(result, "whisper_full returned a non-zero status code");
        return result;
    }

    const int n_segments = whisper_full_n_segments(ctx);
    auto *segments = static_cast<CoreAISegment *>(std::calloc(static_cast<size_t>(n_segments), sizeof(CoreAISegment)));
    if (!segments) {
        set_error(result, "allocation failure building segment array");
        return result;
    }

    for (int i = 0; i < n_segments; ++i) {
        segments[i].start_ms = whisper_full_get_segment_t0(ctx, i) * 10.0; // whisper reports centiseconds
        segments[i].end_ms   = whisper_full_get_segment_t1(ctx, i) * 10.0;
        segments[i].text     = coreai_strdup(std::string(whisper_full_get_segment_text(ctx, i)));
    }

    result->segments       = segments;
    result->segment_count  = n_segments;
    result->success        = true;
    std::memset(result->error_message, 0, sizeof(result->error_message));

    // Detected (or forced) language, as its ISO-639-1 code.
    const int lang_id = whisper_full_lang_id(ctx);
    const char *lang_str = lang_id >= 0 ? whisper_lang_str(lang_id) : "en";
    std::strncpy(result->detected_language, lang_str, sizeof(result->detected_language) - 1);

    return result;
}

void coreai_whisper_free_result(CoreAITranscriptResult *result) {
    if (!result) return;
    for (int32_t i = 0; i < result->segment_count; ++i) {
        std::free(const_cast<char *>(result->segments[i].text));
    }
    std::free(result->segments);
    std::free(result);
}

void coreai_whisper_free(WhisperContextHandle ctx) {
    if (!ctx) return;
    whisper_free(static_cast<struct whisper_context *>(ctx));
    // Caller (Swift side) is responsible for yielding a run-loop turn
    // (~200ms) after this returns before calling coreai_llama_init, so
    // the OS has a chance to actually reclaim these pages before the
    // next model's mmap/allocation pressure begins.
}

// ---------------------------------------------------------------------------
// Engine 2: llama.cpp
// ---------------------------------------------------------------------------

namespace {
struct LlamaBundle {
    llama_model   *model = nullptr;
    llama_context *ctx   = nullptr;
};
} // namespace

LlamaContextHandle coreai_llama_init(const char *model_path) {
    if (!model_path) return nullptr;

    llama_backend_init();

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 999; // offload as much of the 4-bit GGUF as Metal allows

    llama_model *model = llama_model_load_from_file(model_path, mparams);
    if (!model) return nullptr;

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx    = 4096;
    cparams.n_threads = 4;
    cparams.n_threads_batch = 4;

    llama_context *ctx = llama_init_from_model(model, cparams);
    if (!ctx) {
        llama_model_free(model);
        return nullptr;
    }

    auto *bundle = new LlamaBundle{model, ctx};
    return static_cast<LlamaContextHandle>(bundle);
}

char *coreai_llama_summarize(LlamaContextHandle handle, const char *transcript_utf8) {
    auto *bundle = static_cast<LlamaBundle *>(handle);
    if (!bundle || !bundle->ctx || !transcript_utf8) return nullptr;

    const std::string prompt =
        "<start_of_turn>user\n"
        "Summarize the following transcript in 3-5 concise sentences. "
        "Do not invent facts not present in the text.\n\n" +
        std::string(transcript_utf8) +
        "<end_of_turn>\n<start_of_turn>model\n";

    const llama_vocab *vocab = llama_model_get_vocab(bundle->model);

    std::vector<llama_token> tokens(prompt.size() + 32);
    const int n_tokens = llama_tokenize(vocab, prompt.c_str(), static_cast<int32_t>(prompt.size()),
                                         tokens.data(), static_cast<int32_t>(tokens.size()),
                                         /*add_special=*/true, /*parse_special=*/true);
    if (n_tokens < 0) return nullptr;
    tokens.resize(n_tokens);

    llama_batch batch = llama_batch_get_one(tokens.data(), n_tokens);
    if (llama_decode(bundle->ctx, batch) != 0) {
        return nullptr;
    }

    llama_sampler *sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.4f));
    llama_sampler_chain_add(sampler, llama_sampler_init_greedy());

    std::string output;
    const int max_new_tokens = 256;
    llama_token new_token = 0;

    for (int i = 0; i < max_new_tokens; ++i) {
        new_token = llama_sampler_sample(sampler, bundle->ctx, -1);
        if (llama_vocab_is_eog(vocab, new_token)) break;

        char piece[256];
        const int n = llama_token_to_piece(vocab, new_token, piece, sizeof(piece), 0, true);
        if (n > 0) output.append(piece, n);

        llama_batch next = llama_batch_get_one(&new_token, 1);
        if (llama_decode(bundle->ctx, next) != 0) break;
    }

    llama_sampler_free(sampler);
    return coreai_strdup(output);
}

void coreai_llama_free_string(char *str) {
    std::free(str);
}

void coreai_llama_free(LlamaContextHandle handle) {
    auto *bundle = static_cast<LlamaBundle *>(handle);
    if (!bundle) return;
    if (bundle->ctx)   llama_free(bundle->ctx);
    if (bundle->model) llama_model_free(bundle->model);
    llama_backend_free();
    delete bundle;
}

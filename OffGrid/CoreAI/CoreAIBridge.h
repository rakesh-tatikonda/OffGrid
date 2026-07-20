//
//  CoreAIBridge.h
//  OffGrid
//
//  Pure C-linkage boundary between Swift and the C++ inference engines
//  (whisper.cpp + llama.cpp). Everything crossing this boundary is a
//  plain-old-data type or an opaque handle so Swift's C interop can see it
//  without needing to understand C++ name mangling or STL types.
//
//  This header declares NO business logic — only the lifecycle contract.
//  Implementation lives in CoreAIBridge.cpp.
//

#ifndef CoreAIBridge_h
#define CoreAIBridge_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Opaque Handles

/// Opaque pointer to a live whisper.cpp context. Never dereferenced in Swift.
typedef void *WhisperContextHandle;

/// Opaque pointer to a live llama.cpp context (model + context together).
typedef void *LlamaContextHandle;

#pragma mark - Result Types (POD, Swift-visible)

typedef struct {
    double      start_ms;
    double      end_ms;
    const char *text;          // UTF-8, owned by the result; freed by coreai_whisper_free_result
} CoreAISegment;

typedef struct {
    CoreAISegment *segments;       // heap array, length = segment_count
    int32_t        segment_count;
    char           detected_language[8];  // ISO-639-1 code, NUL-terminated
    bool           success;
    char           error_message[256];    // valid only when success == false
} CoreAITranscriptResult;

#pragma mark - Engine 1: whisper.cpp lifecycle

/// Loads a GGML/Core-ML-accelerated whisper model from disk.
/// Returns NULL on failure — caller must check before proceeding.
WhisperContextHandle coreai_whisper_init(const char *model_path);

/// Runs full transcription/translation over a mono 16kHz 16-bit PCM buffer.
/// `pcm_samples` must already be normalized float32 in [-1, 1], `sample_count`
/// is the number of samples (NOT bytes). `language_code` is an ISO-639-1 code
/// or "auto". `translate_to_english` mirrors whisper_full_params.translate.
///
/// The returned pointer must be released with coreai_whisper_free_result.
CoreAITranscriptResult *coreai_whisper_transcribe(WhisperContextHandle ctx,
                                                   const float *pcm_samples,
                                                   int64_t sample_count,
                                                   const char *language_code,
                                                   bool translate_to_english);

/// Frees a result returned by coreai_whisper_transcribe. Safe to call with NULL.
void coreai_whisper_free_result(CoreAITranscriptResult *result);

/// Frees the whisper context. MUST be called before coreai_llama_init to keep
/// peak RSS under the LMK jetsam threshold. Safe to call with NULL.
void coreai_whisper_free(WhisperContextHandle ctx);

#pragma mark - Engine 2: llama.cpp lifecycle

/// Loads a 4-bit quantized GGUF text model. Must only be called AFTER
/// coreai_whisper_free has completed and the caller has yielded at least
/// one run-loop turn so the OS can reclaim the whisper context's pages.
LlamaContextHandle coreai_llama_init(const char *model_path);

/// Runs a single summarization pass over `transcript_utf8`. Returns a
/// heap-allocated, NUL-terminated UTF-8 C string owned by the caller —
/// release it with coreai_llama_free_string. Returns NULL on failure.
char *coreai_llama_summarize(LlamaContextHandle ctx, const char *transcript_utf8);

/// Frees a string returned by coreai_llama_summarize. Safe to call with NULL.
void coreai_llama_free_string(char *str);

/// Frees the llama context and its underlying model. Safe to call with NULL.
void coreai_llama_free(LlamaContextHandle ctx);

#ifdef __cplusplus
}
#endif

#endif /* CoreAIBridge_h */

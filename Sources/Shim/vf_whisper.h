// Thin C wrapper around whisper.cpp so Swift never touches whisper_full_params directly.
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct vf_ctx vf_ctx;

// Load a ggml whisper model (Metal GPU). vad_path: optional Silero VAD ggml model (may be NULL);
// with VAD, clips without speech return "" and leading/trailing silence is trimmed.
// Returns NULL on failure.
vf_ctx *vf_load(const char *model_path, const char *vad_path, bool verbose);
// 1 if the loaded model's encoder runs through Core ML / Neural Engine.
int vf_uses_coreml(vf_ctx *ctx);
void vf_free(vf_ctx *ctx);

// Transcribe 16 kHz mono float PCM.
//  language:  "auto" (decides between ru/en only, biased to ru), "ru", "en", ...
//  prompt:    initial prompt (dictionary / style priming), may be NULL
//  fast:      shrink the encoder window to the clip length (big speed-up for short clips)
// Writes UTF-8 text into out; detected_lang gets the language used (>= 8 bytes).
// Returns 0 on success.
int vf_transcribe(vf_ctx *ctx, const float *samples, int n_samples,
                  const char *language, const char *prompt, int n_threads, bool fast,
                  char *out, int out_size, char *detected_lang);

// Run the model once on a second of near-silence, so the first real dictation is not slowed by
// one-time setup (the Neural Engine's first run takes seconds).
void vf_warmup(vf_ctx *ctx, int n_threads);

#ifdef __cplusplus
}
#endif

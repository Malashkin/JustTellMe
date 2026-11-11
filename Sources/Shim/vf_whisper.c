#include "vf_whisper.h"
#include "whisper.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct vf_ctx {
    struct whisper_context *w;
    struct whisper_vad_context *vad;
};

static bool g_verbose = false;

// Smallest encoder window (frames of 20 ms). Very small windows hurt accuracy on short clips.
#define MIN_AUDIO_CTX 384
// Segments whose no-speech probability is above this are dropped.
#define NO_SPEECH_DROP 0.6f

static void vf_log(enum ggml_log_level level, const char *text, void *user) {
    (void)user;
    if (g_verbose || level >= GGML_LOG_LEVEL_ERROR) fputs(text, stderr);
}

vf_ctx *vf_load(const char *model_path, const char *vad_path, bool verbose) {
    g_verbose = verbose || getenv("JTM_VERBOSE") != NULL;
    whisper_log_set(vf_log, NULL);

    struct whisper_context_params cp = whisper_context_default_params();
    cp.use_gpu = true;
    cp.flash_attn = true;

    struct whisper_context *w = whisper_init_from_file_with_params(model_path, cp);
    if (!w) return NULL;
    vf_ctx *c = (vf_ctx *)calloc(1, sizeof(vf_ctx));
    c->w = w;
    if (vad_path && *vad_path) {
        struct whisper_vad_context_params vp = whisper_vad_default_context_params();
        vp.n_threads = 2;
        vp.use_gpu = false; // tiny LSTM, CPU is fastest
        c->vad = whisper_vad_init_from_file_with_params(vad_path, vp);
        if (!c->vad) fprintf(stderr, "vf: VAD model failed to load: %s\n", vad_path);
    }
    return c;
}

void vf_free(vf_ctx *ctx) {
    if (!ctx) return;
    whisper_free(ctx->w);
    if (ctx->vad) whisper_vad_free(ctx->vad);
    free(ctx);
}

// Encoder frames are 20 ms (320 samples). Round up to a multiple of 64 with a margin.
static int audio_ctx_for(struct whisper_context *w, int n_samples) {
    int max_ctx = whisper_n_audio_ctx(w);
    int frames = n_samples / 320;
    if (frames >= max_ctx - 128) return 0; // long clip: full 30 s window
    static int min_ctx = -1;
    if (min_ctx < 0) min_ctx = getenv("JTM_MIN_AUDIO_CTX") ? atoi(getenv("JTM_MIN_AUDIO_CTX")) : MIN_AUDIO_CTX;
    int c = ((frames + 128 + 63) / 64) * 64;
    if (c < min_ctx) c = min_ctx;
    return c >= max_ctx ? 0 : c;
}

static const char *pick_ru_en(struct whisper_context *w, const float *samples, int n_samples,
                              int n_threads, bool fast) {
    const char *lang = "ru";
    int nl = whisper_lang_max_id() + 1;
    float *probs = (float *)calloc((size_t)nl, sizeof(float));
    // Detection needs only the first few seconds: use a small encoder window.
    // Window sized to the clip (capped at 8 s): much cheaper than the full 30 s. A fixed
    // 5 s window was tested and misdetected Russian as English, so don't go smaller.
    whisper_set_audio_ctx(w, fast ? audio_ctx_for(w, n_samples < 16000 * 8 ? n_samples : 16000 * 8) : 0);
    if (whisper_pcm_to_mel(w, samples, n_samples, n_threads) == 0 &&
        whisper_lang_auto_detect(w, 0, n_threads, probs) >= 0) {
        float pru = probs[whisper_lang_id("ru")];
        float pen = probs[whisper_lang_id("en")];
        // Close Slavic languages count as Russian.
        const char *slavic[] = {"uk", "be", "bg", "sr", "mk", "kk", "pl"};
        for (size_t i = 0; i < sizeof(slavic) / sizeof(slavic[0]); i++) {
            int id = whisper_lang_id(slavic[i]);
            if (id >= 0) pru += probs[id];
        }
        // Bias towards Russian when unsure (mixed speech is mostly Russian with English terms).
        lang = (pen > 2.0f * pru) ? "en" : "ru";
        if (g_verbose) fprintf(stderr, "vf: lang probs ru*=%.3f en=%.3f -> %s\n", pru, pen, lang);
    }
    free(probs);
    return lang;
}

static int run_full(struct whisper_context *w, const float *samples, int n_samples, const char *lang,
                    const char *prompt, int n_threads, int audio_ctx, char *out, int out_size) {
    struct whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads = n_threads;
    p.language = lang;
    p.detect_language = false;
    p.translate = false;
    p.no_context = true;
    p.no_timestamps = true;
    p.single_segment = false;
    p.print_progress = false;
    p.print_realtime = false;
    p.print_special = false;
    p.print_timestamps = false;
    p.suppress_blank = true;
    p.suppress_nst = true;
    p.audio_ctx = audio_ctx;
    p.initial_prompt = (prompt && *prompt) ? prompt : NULL;

    if (whisper_full(w, p, samples, n_samples) != 0) return -2;

    int pos = 0;
    int n = whisper_full_n_segments(w);
    for (int i = 0; i < n; i++) {
        const char *t = whisper_full_get_segment_text(w, i);
        if (!t) continue;
        float nsp = whisper_full_get_segment_no_speech_prob(w, i);
        if (g_verbose) fprintf(stderr, "vf: segment %d no_speech=%.3f: %s\n", i, nsp, t);
        if (nsp > NO_SPEECH_DROP) continue; // hallucination on silence/noise
        int len = (int)strlen(t);
        if (pos + len >= out_size - 1) len = out_size - 1 - pos;
        if (len <= 0) break;
        memcpy(out + pos, t, (size_t)len);
        pos += len;
    }
    out[pos] = 0;
    if (g_verbose) whisper_print_timings(w);
    return 0;
}

static bool blank(const char *s) {
    for (; *s; s++) if (*s != ' ' && *s != '\n' && *s != '\t') return false;
    return true;
}

int vf_uses_coreml(vf_ctx *ctx) { return ctx ? whisper_uses_coreml(ctx->w) : 0; }

int vf_transcribe(vf_ctx *ctx, const float *samples, int n_samples,
                  const char *language, const char *prompt, int n_threads, bool fast,
                  char *out, int out_size, char *detected_lang) {
    if (!ctx || !samples || n_samples <= 0 || !out || out_size <= 0) return -1;
    out[0] = 0;
    struct whisper_context *w = ctx->w;
    // Core ML (Neural Engine) encoders have a fixed 30 s window: a shorter audio_ctx would not match.
    if (whisper_uses_coreml(w)) fast = false;

    // Voice activity detection: skip clips with no speech (whisper hallucinates on noise) and
    // trim silence at the start/end of push-to-talk recordings (shorter audio = faster encode).
    if (ctx->vad) {
        struct whisper_vad_params vp = whisper_vad_default_params();
        vp.threshold = 0.4f;
        vp.min_speech_duration_ms = 150;
        struct whisper_vad_segments *seg = whisper_vad_segments_from_samples(ctx->vad, vp, samples, n_samples);
        int ns = seg ? whisper_vad_segments_n_segments(seg) : -1;
        if (ns == 0) {
            if (g_verbose) fprintf(stderr, "vf: VAD: no speech\n");
            whisper_vad_free_segments(seg);
            if (detected_lang) detected_lang[0] = 0;
            return 0;
        }
        if (ns > 0) {
            int a = (int)(whisper_vad_segments_get_segment_t0(seg, 0) * 160.0f) - 16000 / 4;   // cs -> samples, -250 ms
            int b = (int)(whisper_vad_segments_get_segment_t1(seg, ns - 1) * 160.0f) + 16000 * 3 / 10; // +300 ms
            if (a < 0) a = 0;
            if (b > n_samples) b = n_samples;
            // Pauses inside are kept on purpose: cutting them out made whisper loop on the last phrase
            // and fall back to temperature sampling (3x slower, sometimes garbage) on some clips.
            if (b - a >= 16000 / 2) {
                if (g_verbose) fprintf(stderr, "vf: VAD: %d segment(s), trim %.2f..%.2f of %.2fs\n",
                                       ns, a / 16000.0, b / 16000.0, n_samples / 16000.0);
                samples += a;
                n_samples = b - a;
            }
        }
        if (seg) whisper_vad_free_segments(seg);
    }
    // whisper needs >= 1 s; pad short clips with silence (static buffer reused across calls).
    static float *padbuf = NULL;
    if (n_samples < 17600) {
        padbuf = (float *)realloc(padbuf, 17600 * sizeof(float));
        memset(padbuf, 0, 17600 * sizeof(float));
        memcpy(padbuf, samples, (size_t)n_samples * sizeof(float));
        samples = padbuf;
        n_samples = 17600;
    }

    const char *lang = (language && *language) ? language : "auto";
    if (strcmp(lang, "auto") == 0) {
        lang = whisper_is_multilingual(w) ? pick_ru_en(w, samples, n_samples, n_threads, fast) : "en";
    }
    if (detected_lang) {
        strncpy(detected_lang, lang, 7);
        detected_lang[7] = 0;
    }

    int actx = fast ? audio_ctx_for(w, n_samples) : 0;
    if (g_verbose) fprintf(stderr, "vf: audio_ctx=%d lang=%s\n", actx, lang);
    int rc = run_full(w, samples, n_samples, lang, prompt, n_threads, actx, out, out_size);
    if (rc == 0 && actx != 0 && blank(out)) {
        // Reduced window produced nothing: retry with the full 30 s window.
        if (g_verbose) fprintf(stderr, "vf: empty result, retry with full audio_ctx\n");
        rc = run_full(w, samples, n_samples, lang, prompt, n_threads, 0, out, out_size);
    }
    return rc;
}

void vf_warmup(vf_ctx *ctx, int n_threads) {
    if (!ctx) return;
    // One encoder + decoder pass on a second of quiet noise (no VAD: it would skip silence).
    float *buf = (float *)malloc(17600 * sizeof(float));
    unsigned r = 12345;
    for (int i = 0; i < 17600; i++) { r = r * 1103515245u + 12345u; buf[i] = ((int)(r >> 16 & 0x7fff) - 16384) / 16384.0f * 0.001f; }
    char out[256];
    run_full(ctx->w, buf, 17600, "en", NULL, n_threads, 0, out, sizeof(out));
    free(buf);
}

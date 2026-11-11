---
audience: all
owner: Malashkin
updated: 2026-11-11
---

# 008. Keep pauses inside a clip (cutting them out was rejected)

**Status:** Rejected (2026-11-11)

## Context
VAD already trims silence before the first and after the last word. The idea was to also cut long pauses inside a
clip (keep ±0.25–1 s around each speech segment): less audio means a smaller encoder window and less work.

## What was measured
Five TTS clips with 2–4 s pauses, GPU, `--repeat 2`:
- The encoder got ~2× faster (1.5 s vs 2.8 s) and two clips came out cleaner.
- On two clips ending in a short phrase, whisper looped on that phrase («И третья. И третья. И треть»). It then
  fell back to temperature sampling 4 times: 7–11 s instead of ~3 s, once with garbage text.
- Every tested margin (250/300, 400/600, 700/1300, 1000/1000 ms) and the full encoder window showed the same.
  Turning temperature fallback off left a broken tail that the repeat cleanup cannot fix.

## Decision
Don't cut pauses inside a clip. While speaking, streaming (ADR 002) already splits long speech at pauses, so
the pieces rarely contain long pauses.

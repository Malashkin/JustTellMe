---
audience: all
owner: Malashkin
updated: 2026-11-10
---

# 003. Neural Engine as an opt-in setting

**Status:** Accepted (2026-11-09)

## Context
On the GPU, encoding takes 7–9 s when other apps keep the GPU busy. The Core ML encoder on the Neural Engine takes
0.8–1.0 s. However:
- the encoder is a 1.2 GB download;
- the first load is compiled by macOS for 13–25 min on M1;
- that compilation is cached per binary, so it can happen again after every update.

## Decision
- Build whisper.cpp with `WHISPER_COREML=ON` and fallback allowed.
- A local patch makes the Core ML encoder load only when `JTM_COREML_ENCODER` is set.
- In the app the setting is off by default. When it is on:
  1. download the encoder for the active model from the whisper.cpp model repo;
  2. pre-load it in the background with `MLModel(contentsOf:)` (`.all` compute units);
  3. reload whisper with the encoder once it is ready.
- Dictation stays on the GPU until then.

## Consequences
- With the setting on, waits are about 5× shorter, and other apps using the GPU stop slowing dictation down.
- The cost is about 1 GB more memory, a one-time download, and possible re-preparation after updates.
- Core ML encoders have a fixed 1500 audio context, so the shorter audio-context speed-up is disabled when Core ML is active.

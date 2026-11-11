---
audience: all
owner: Malashkin
updated: 2026-11-11
---

# 006. Free the model when idle, reload on the GPU first

**Status:** Accepted (2026-11-11)

## Context
The model kept ~0.7 GB (671 MB footprint measured) in memory all day, because «Выгружать модель» defaulted to «никогда».
That matters on 8 GB Macs. Reloading costs 0.4–0.7 s on the GPU, but 4.5 s with the Core ML encoder, and the first
Neural Engine run after loading takes another ~2 s.

## Decision
- Default `unloadAfterMinutes` = 15. An explicit choice (including «никогда») is kept.
- Key down calls `prewarm()`. After an unload it loads the model **GPU only**, which finishes while the user is still speaking.
- With Neural Engine on, once that dictation is done, a second context with the encoder is loaded and warmed up
  (`vf_warmup`, one pass on a second of quiet noise) on a background queue, then swapped in on the inference queue
  between dictations. Not earlier, so it does not slow down the dictation itself. The swap is
  dropped if anything changed meanwhile (other model, unloaded again).

## Consequences
- Measured (`--unload-cycle`): reload 0.36 s (GPU) / 0.57 s (Neural Engine setting), same text as before the unload,
  encoder attached again ~13 s later.
- For a few seconds after a reload both contexts are in memory.
- `JTM_COREML_ENCODER` is a process-wide environment variable, so all `vf_load` calls are serialised with a lock.

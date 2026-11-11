---
audience: all
owner: Malashkin
updated: 2026-11-10
---

# 001. Local recognition with a static whisper.cpp

**Status:** Accepted (2026-11-08)

## Context
We wanted a Wispr Flow replacement for Russian speech with English terms: private, offline, and easy to copy to another
Mac without installing Homebrew or Python there.

## Decision
- Link whisper.cpp statically, with Metal shaders embedded, Accelerate BLAS and no OpenMP. Pin it to a commit and apply a small local patch.
- Bundle `large-v3-turbo-q5_0` (574 MB) inside the `.app`.

## Consequences
- The app is self-contained, and no audio leaves the Mac.
- The bundle is about 600 MB, and the first `build.sh` downloads the model.

## Alternatives considered
- **GigaAM v3** is about 7× faster, but it transliterated or dropped English terms.
- **Parakeet v3** was worse on mixed Russian/English speech.

Both were benchmarked on 2026-11-09 against the same phrases. Whisper had a WER of 7.7% and kept English terms in Latin.

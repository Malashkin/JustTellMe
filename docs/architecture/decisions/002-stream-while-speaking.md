---
audience: all
owner: Malashkin
updated: 2026-11-10
---

# 002. Transcribe in pieces while the user speaks

**Status:** Accepted (2026-11-09; pause detection revised 2026-11-10)

## Context
After a 20–25 s dictation, users waited 4–12 s on an 8 GB M1. Encoding a full 30 s window took 7–9 s on a busy GPU,
and a separate language-detection pass added about 60%.

## Decision
- While recording, once 8 s or more is pending, cut a piece at the latest pause (0.3 s or longer, piece at least 5 s), and force a cut at 25 s. Send the piece to Whisper right away.
- Prime each piece with the prompt plus the last 150 characters of the previous piece's text.
- Drop the detection pass: `auto` decodes as Russian, and the label comes from the script (counting words).
- The quiet level is the quietest 0.3 s stretch in the audio. A percentile of loudness missed real pauses in fluent speech; the tests caught this.

## Consequences
- Text is ready about 1–1.7 s after release for 11–33 s of speech (measured on TTS).
- Piece boundaries can break a sentence. This is mitigated by the context carried over from the previous piece.
- A piece after an English piece is decoded as English. That is why the language label must count words, not letters.

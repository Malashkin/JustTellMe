---
audience: testing
owner: Malashkin
updated: 2026-11-10
---

# Testing

How to run the tests and what they cover. Up: [AGENTS.md](../AGENTS.md). Why there is no XCTest: [ADR 004](../architecture/decisions/004-plain-test-executable.md).
Latest run and mutation results: [TEST_RESULTS.md](../../TEST_RESULTS.md).

## Run

```bash
./build.sh                       # once: builds whisper.cpp and the app the integration tests drive
scripts/test.sh                  # everything, ~35 s
JTM_SKIP_SLOW=1 scripts/test.sh  # without the two speech-recognition tests, ~9 s
```

Exit code 0 means everything passed. Failures are listed at the end with `file:line`.
The run uses a fresh temporary `JTM_SUPPORT_DIR`, so your history, dictionary and models are never touched.

## Layout

| File | Layer | What it covers |
|---|---|---|
| `Tests/Harness.swift` | — | `T.test` / `T.eq` / `T.ok`, `SeededRandom` for deterministic property tests |
| `Tests/UnitTests.swift` | unit | stats and streak, Russian plurals and durations, hallucination cleanup, auto-language, streaming cut points (16/48 kHz), correction learning, rule parsing, Neural Engine file names |
| `Tests/IntegrationTests.swift` | integration | history file, personal dictionary end to end, built-in dictionary (no client names, checked by hash; valid rules), the app binary (`--learn`, `--list-models`, TTS speech via `--transcribe` and `--stream`) |
| `Tests/main.swift` | — | runs everything, prints a summary |

## Writing a test

- Assert what the feature promises the user, not what the code currently returns.
- Pure logic should be a `static func`, so it can be called directly.
- Anything that touches files must go through `Paths` (it honours `JTM_SUPPORT_DIR`).
- Speech audio comes from `say -v Milena|Samantha … --data-format=LEI16@16000`. Assert keywords, not exact text.
- Bugfix: first add a test that fails on the bug, then fix.

## Not automated

The hotkey, microphone capture, pasting into other apps, windows and menus. These need a live session with
Accessibility and Microphone. Check them by hand after UI changes. Use `--demo-window out` to render the pages to PNG.

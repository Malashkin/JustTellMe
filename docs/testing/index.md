---
audience: testing
owner: Malashkin
updated: 2026-11-11
---

# Testing

How to run the tests and what they cover. Up: [AGENTS.md](../AGENTS.md). Why there is no XCTest: [ADR 004](../architecture/decisions/004-plain-test-executable.md).
Latest run and mutation results: [TEST_RESULTS.md](../../TEST_RESULTS.md).

## Run

```bash
./build.sh                       # once: builds whisper.cpp and the app the integration tests drive
scripts/test.sh                  # everything, ~3 min (speech recognition, update archives of a 550 MB app)
JTM_SKIP_SLOW=1 scripts/test.sh  # pure logic + quick binary checks, ~3 s after compiling
```

Exit code 0 means everything passed. Failures are listed at the end with `file:line`.
The run uses a fresh temporary `JTM_SUPPORT_DIR`, so your history, dictionary and models are never touched.

## Layout

| File | Layer | What it covers |
|---|---|---|
| `Tests/Harness.swift` | — | `T.test` / `T.eq` / `T.ok`, `SeededRandom` for deterministic property tests |
| `Tests/UnitTests.swift` | unit | stats and streak, Russian plurals and durations, hallucination cleanup, auto-language, streaming cut points (16/48 kHz), correction learning, rule parsing, Neural Engine file names |
| `Tests/FeatureTests.swift` | unit | 1.1 features: unload default, trailing space for paste-again, «is a text field focused» decisions (incl. Chrome/Electron), version order and GitHub release parsing, waveform bars |
| `Tests/IntegrationTests.swift` | integration | history file, personal dictionary end to end, built-in dictionary (no client names, checked by hash; valid rules), the app binary (`--learn`, `--list-models`, TTS speech via `--transcribe` and `--stream`, reload after idle via `--unload-cycle`), update archives via `--update-stage` (accepted; wrong version, modified, other certificate, other app refused) |
| `Tests/main.swift` | — | runs everything, prints a summary |

## Writing a test

- Assert what the feature promises the user, not what the code currently returns.
- Pure logic should be a `static func`, so it can be called directly.
- Anything that touches files must go through `Paths` (it honours `JTM_SUPPORT_DIR`).
- Speech audio comes from `say -v Milena|Samantha … --data-format=LEI16@16000`. Assert keywords, not exact text.
- Bugfix: first add a test that fails on the bug, then fix.

## Not automated

The hotkey, ⌃⌥V, microphone capture, pasting into other apps, windows and menus, a real update download (checked
by hand with `--update-install` against a copy of the app). These need a live session with
Accessibility and Microphone. Check them by hand after UI changes. Use `--demo-window out` to render the pages to PNG.

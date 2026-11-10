# Test Results

**Date:** 2026-11-10 · **Status:** 🟢 PASS
**Stack:** Swift 5.10 + C shim (whisper.cpp), macOS desktop app, Command Line Tools only (no XCTest)
**Runner:** `scripts/test.sh` (a test executable built from `Sources/App` + `Tests/`; `JTM_SKIP_SLOW=1` skips speech recognition)
**Isolation:** every run uses a fresh temporary `JTM_SUPPORT_DIR`, so real history, dictionary and models are never touched.

| Layer | Tests | Result | Covers |
|---|---|---|---|
| Unit | 47 (incl. 2 property-based) | ✅ | stats and streak, Russian plural/duration formatting, hallucination cleanup, auto-language, streaming cut points (16/48 kHz), correction learning, rule parsing, Neural Engine file names |
| Integration (files) | 10 (incl. 1 property-based) | ✅ | history save/delete/clear and JSON round trip, personal dictionary and replacements end to end, save/load from the dictionary page, built-in dictionary (no client names, all rules valid) |
| Integration (app binary) | 4 | ✅ | `--learn`, `--list-models`, Russian speech with English terms (TTS), long dictation streamed in pieces (2 pieces early, **ready 1.67 s after release**, GPU) |
| Contract / E2E | N/A | – | no API; the GUI isn't automatable here (no Screen Recording / UI test runner) |

**Total:** 61 passed, 0 failed, 0 skipped, 36.6 s.

## Mutation testing

No Swift mutation tool is installed, so 14 hand-picked mutants were applied to the risky logic one at a time
(scripted, fast suite each time):

**Score: 14/14 killed.** Mutants: saved time sign and floor, wpm unit, streak without today, plural for 11,
8-day week, en/ru tie, long phrase dropped as junk, repeat collapse removed, cut before 5 s, earliest instead of
latest pause, rule size limit, case-only term lost, casing applied to English.

## Coverage

Not measured: no coverage tooling for a swiftc-only build. Uncovered by design: AppKit windows and menus,
the global hotkey, microphone capture and pasting (they need a real session with Accessibility/Microphone).

## Defects found and fixed (regression tests stay)

1. **Auto-language counted letters, not words.** "Посмотри pull request и сделай deploy" was labelled English. In
   streaming that would make the *next* piece decode as English. Fixed in `Transcriber.scriptLanguage`.
   Test: `language: Russian with a few English terms stays Russian`.
2. **Pause detection missed clear pauses in fluent speech.** The quiet level was the 15th percentile of loudness,
   so when pauses were under ~15% of the audio everything counted as "quiet" and a 0.6 s pause was ignored (the
   piece was then cut only at the forced 25 s mark). Now the quiet level is the quietest 0.3 s stretch, and
   "no real contrast" means no pause. Fixed in `StreamingDictation.findCut`.
   Tests: `stream: cuts in the middle of a pause…`, `…latest pause…`, `…48 kHz`.

## Not tested

- The dictated text is no longer written to the system log (this session's cleanup). The log call sits in the
  hotkey/recording path, which needs a live session.
- History trimming at 2000 entries (would need 2000 file writes; slow).

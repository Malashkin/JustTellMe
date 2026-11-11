# Test Results

**Date:** 2026-11-11 (v1.1.2) · **Status:** 🟢 PASS
**Stack:** Swift 5.10 + C shim (whisper.cpp), macOS desktop app, Command Line Tools only (no XCTest)
**Runner:** `scripts/test.sh` (a test executable built from `Sources/App` + `Tests/`; `JTM_SKIP_SLOW=1` skips speech recognition)
**Isolation:** every run uses a fresh temporary `JTM_SUPPORT_DIR`, so real history, dictionary and models are never touched.

| Layer | Tests | Result | Covers |
|---|---|---|---|
| Unit | 47 (incl. 2 property-based) | ✅ | stats and streak, Russian plural/duration formatting, hallucination cleanup, auto-language, streaming cut points (16/48 kHz), correction learning, rule parsing, Neural Engine file names |
| Integration (files) | 10 (incl. 1 property-based) | ✅ | history save/delete/clear and JSON round trip, personal dictionary and replacements end to end, save/load from the dictionary page, built-in dictionary (no client names, all rules valid) |
| Unit, v1.1 features | 20 (incl. 4 property-based) | ✅ | unload default and explicit «никогда», trailing space for ⌃⌥V, «is a text field focused» (text/none/unknown, Chrome/Electron never «none», AX errors), version order, GitHub release parsing (drafts, missing zip, garbage), version from the `releases/latest` redirect, waveform bars |
| Integration (app binary) | 10 | ✅ | `--learn`, `--list-models`, Russian speech with English terms (TTS), long dictation streamed in pieces (2 pieces early, **ready 0.83 s after release**, GPU), **reload after idle unload 0.22 s** with the same text, the idle timer frees the model even if it was used after being armed, update archives: this build accepted; wrong version, modified after signing, other certificate, other app refused; a release zip installed over another copy (no hang, no leftovers) |
| Contract / E2E | N/A | – | no API; the GUI isn't automatable here (no Screen Recording / UI test runner) |

**Total:** 91 passed, 0 failed, 0 skipped, 157 s (fast suite: 81 passed, 3 s).

## Mutation testing

No Swift mutation tool is installed, so 14 hand-picked mutants were applied to the risky logic one at a time
(scripted, fast suite each time):

**Score: 14/14 killed.** Mutants: saved time sign and floor, wpm unit, streak without today, plural for 11,
8-day week, en/ru tie, long phrase dropped as junk, repeat collapse removed, cut before 5 s, earliest instead of
latest pause, rule size limit, case-only term lost, casing applied to English.

**v1.1: 11/11 killed.** Version order reversed, editable element ignored, «nothing focused» always «no field»,
Chrome/Electron check removed, draft releases accepted, no space after «…», unload default «never», idle pulse
of the bars removed, update signature not verified, update version not checked, swap script waiting on PID 0.

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

## Checked by hand (v1.1)

- Focus detection on real apps through the app's own Accessibility grant: TextEdit and Terminal → text field;
  Finder → no field; VS Code, Chrome, Safari → unknown (no card).
- Recording pill: CPU for a 6 s demo 0.22 s → 0.09 s, 780 M → 330 M instructions (incl. process start); PNG
  render looks the same.
- Pause cutting inside clips was measured and rejected (ADR 008).
- **Real update end to end:** a copy of the app relabelled 1.0.0 (re-signed) found v1.1.0 on GitHub, downloaded
  JustTellMe.zip (513 MB, 24 s), verified it, replaced itself after quitting and came back as 1.1.0 with a valid
  signature and no quarantine flag.

## Defects found by this round (fixed)

- The GitHub API answered 403 on the first real check: its 60 requests/hour per IP were used up. The updater now
  falls back to the `releases/latest` page (1.1.1).
- Each refused update archive left an unpacked ~550 MB app in the temporary folder; the test runs had piled up
  11 GB. Refused archives are now deleted (1.1.1).
- Installing over another copy (not the running app) hung: the swap script waited on PID 0, and `kill -0 0` is
  the whole process group. Self-updates were unaffected. Fixed; the new install test timed out before the fix.
- **The idle unload never happened after launch.** Found by measuring the installed app: still 681 MB after the idle
  time. The timer fired once and gave up because the model had finished loading after it was armed. It now re-arms
  for the rest of the time (1.1.2). Test `binary: the idle timer frees the model even if it was used after…` was red
  before the fix.

## Not tested

- The dictated text is no longer written to the system log (this session's cleanup). The log call sits in the
  hotkey/recording path, which needs a live session.
- History trimming at 2000 entries (would need 2000 file writes; slow).
- ⌃⌥V and the card's buttons: global hotkeys and clicks need a live session.

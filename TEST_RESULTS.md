# Test Results

**Date:** 2026-11-24 (v1.3.0 + Liquid Glass) · **Status:** 🟢 PASS
**Stack:** Swift 5.10 + C shim (whisper.cpp), macOS desktop app, Command Line Tools only (no XCTest)
**Runner:** `scripts/test.sh` (a test executable built from `Sources/App` + `Tests/`; `JTM_SKIP_SLOW=1` skips speech recognition)
**Isolation:** every run uses a fresh temporary `JTM_SUPPORT_DIR`, so real history, dictionary and models are never touched. **Language:** the suite runs with the Russian interface (`JTM_LANG=ru`); `LocalizationTests` switch to English.

| Layer | Tests | Result | Covers |
|---|---|---|---|
| Unit | 47 (incl. 2 property-based) | ✅ | stats and streak, Russian plural/duration formatting, hallucination cleanup, auto-language, streaming cut points (16/48 kHz), correction learning, rule parsing, Neural Engine file names |
| Integration (files) | 10 (incl. 1 property-based) | ✅ | history save/delete/clear and JSON round trip, personal dictionary and replacements end to end, save/load from the dictionary page, built-in dictionary (no client names, all rules valid) |
| Unit, v1.1–1.2 features | 25 (incl. 5 property-based) | ✅ | double tap → hands-free by default, single-tap and hold-only modes, any press ≥ 0.3 s is push-to-talk, unload default and explicit «никогда», trailing space for ⌃⌥V, «is a text field focused» (text/none/unknown, Chrome/Electron never «none», AX errors), version order, GitHub release parsing (drafts, missing zip, garbage), version from the `releases/latest` redirect, waveform bars |
| Integration (app binary) | 10 | ✅ | `--learn`, `--list-models`, Russian speech with English terms (TTS), long dictation streamed in pieces (2 pieces early, **ready 0.83 s after release**, GPU), **reload after idle unload 0.22 s** with the same text, the idle timer frees the model even if it was used after being armed, update archives: this build accepted; wrong version, modified after signing, other certificate, other app refused; a release zip installed over another copy (no hang, no leftovers) |
| Unit + files, voice lists and text selection | 21 | ✅ | command words of Заметки/Задачи («Заметка», «Задача» only as the first whole word, keyword removed, alone → empty), misheard one letter off or split in two («Замевка», «За мефка», «Зодача», «За дача»), lookalikes pasted («Заметна», «Заметкам», «Зачётка», «Задачам», «Удача»…); own lists with several words, short words exact, exact beats a near miss; typed words parsed and checked (empty, multi-word, taken by another list); first run creates Заметки and Задачи and moves `notes.json` once; create/rename/change words and kind/delete a list with its file; entries newest first, reload, search, exact delete; task Done remembers when, Backlog forgets, deadline is a day; filters by status, created/due/done over today/7/30 days/custom range, overdue Backlog in due periods, notes ignore task filters; day groups by the chosen date, deadlines soonest first, undated last; the line under a task (deadline, overdue, done); dated headers incl. «Завтра»; ticks and bulk actions; selectable text and ⌘C; sidebar order |
| Unit, interface language | 4 | ✅ | English texts, plurals and date formats («Today, November 23», «Nov 23, 09:05»), English default lists Notes/Tasks opened by exact «Note»/«Task», switching to Russian changes texts, dates and default lists |
| Unit, Liquid Glass controls and theme | 8 | ✅ | glass colors differ in Light/Dark mode, capsule button title/padding/disabled state, segmented capsule reports a pick once and raises only the chosen segment, the blur mask stretches and the backdrop blends behind the window, checkbox and status capsule centred on the first text line of a task, Auto/Light/Dark saved, applied and announced, icon-only theme switch keeps labels for VoiceOver, window buttons inside the sidebar panel |
| Contract / E2E | N/A | – | no API; the GUI isn't automatable here (no Screen Recording / UI test runner) |

**Total:** 128 passed, 0 failed, 1 skipped (update archive signed by another certificate: this local build is ad-hoc signed, so there is nothing to compare), 70 s (fast suite: 118 passed, 4 s). Every page of the main window was also rendered with `--demo-window` and checked by eye. Stream: ready 0.57 s after release; reload after idle 0.21 s.

## Mutation testing

No Swift mutation tool is installed, so 14 hand-picked mutants were applied to the risky logic one at a time
(scripted, fast suite each time):

**Score: 14/14 killed.** Mutants: saved time sign and floor, wpm unit, streak without today, plural for 11,
8-day week, en/ru tie, long phrase dropped as junk, repeat collapse removed, cut before 5 s, earliest instead of
latest pause, rule size limit, case-only term lost, casing applied to English.

**v1.2 double tap: 3/3 killed** (double tap treated as single tap, old default, hold boundary).

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

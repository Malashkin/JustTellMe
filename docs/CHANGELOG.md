---
audience: all
owner: Malashkin
updated: 2026-11-24
---

# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The app has no version tags yet, so entries are grouped by date.

## [Unreleased]

## [1.3.0] — 2026-11-24

### Added
- **English interface.** The app follows the system language: English, or Russian when macOS prefers Russian. Default lists are Notes/Tasks with the command words Note/Task in English, Заметки/Задачи with Заметка/Задача in Russian. `JTM_LANG=en|ru` forces a language.
- **Voice lists.** Start a dictation with a list's command word and the rest of the phrase is saved to that list instead of being pasted: “Note: call the bank” → Notes, “Task: send the report” → Tasks (on a Russian system «Заметка: позвонить в банк» → Заметки, «Задача: отправить отчёт» → Задачи). A “Saved to “…”” card confirms it, with a button to open the list. Each list is a page in the sidebar; nothing goes to the Home feed or the stats.
- **Own lists and command words.** “New List” in the sidebar creates a list: a name, one or more command words separated by commas (“Idea, Thought”), and a kind — notes (plain entries) or tasks. “Edit List…” on a list renames it, changes its words or kind, or deletes it with its entries (after a confirmation). Notes and Tasks are ordinary lists and can be changed or deleted too.
- **Tasks.** A tasks list adds a status (new tasks are Backlog, then Done, changed per task or for the ticked ones; Done remembers when), a due date (“Due Date…”, overdue ones in red), and filters: status (All / Backlog / Done), which date (Created / Due / Done) and a period (Today, 7 days, 30 days, All dates, or “Custom range…” from–to). Entries are grouped by that date.
- **A misheard command word still counts.** Words of 6 letters or more may be one letter off or split in two; on a Russian system «Замевка», «За мефка» and «Зодача» still count as «Заметка» / «Задача». Real words one letter off («Заметна», «Заметкам», «Зачётка», «Задачам», …) are excluded; shorter words (“Idea”, “Note”, “Task”) must be heard exactly. A word heard exactly wins over a near miss of another list's word.
- **Dates, search, ticks and bulk delete in every list.** Day headers always show the date (“Today, November 23”, “Tomorrow, November 24”), every entry shows its date and time. Tick entries (or “Check All”) and press “Delete N …”; a tick on an entry hidden by a search or filter is dropped.
- **Select and copy part of the text.** On Home and in the lists you can select any part of an entry with the mouse and copy it with ⌘C. ⌘C with whole rows highlighted copies those entries; right-click → Copy.
- `--demo-note-card out.png` renders the “Saved to “Notes”” card.

### Changed
- Notes saved by earlier builds of this branch (`notes.json`) are moved into the first default list (Notes / Заметки) on the first start.
- Documentation and code comments are now in English.

## [1.2.0] — 2026-11-12

### Added
- **Double tap for hands-free dictation, like Wispr Flow.** Double-tap Fn (or the chosen key) and speak without holding it; one more press stops and transcribes. Holding still works as push-to-talk, and a single stray tap does nothing. This is the new default; “Hold, or tap once” and “Hold only” stay in Settings → “How the key works”.

### Fixed
- **The model is really freed after the idle time.** The idle timer fired once and gave up if the model had been used, or had finished loading, after it was armed. Right after launch that is always the case, so the model stayed in memory until the first dictation. It now re-arms for the remaining time.
- `--update-install` of another copy of the app hung forever: the swap script waited on PID 0 (`kill -0 0` means the whole process group). Self-updates were not affected. A test now installs a local release zip over another copy.

### Added
- `--update-install target.app --zip file.zip --version X` installs from a local zip (used by the tests).

## [1.1.1] — 2026-11-11

### Fixed
- **Updates are found even when GitHub's API limit is used up.** The API allows 60 requests an hour per IP address, shared by everyone behind it. On 403/429 the app now reads the version from the `releases/latest` page.
- **A refused update no longer leaves a ~550 MB copy in the temporary folder.**

## [1.1.0] — 2026-11-11

### Added
- **Updates from GitHub Releases.** JustTellMe checks for a new version once a day (can be turned off) and installs it in two clicks: download, signature and certificate check, restart. Permissions stay.
- **⌃⌥V pastes the last dictation again** where the cursor is now (also 🎙 → Paste Last Again).
- **“No text field?” card**: when the text was most likely pasted nowhere (Finder, desktop, a list), it is shown with a Copy button. It stays quiet when it can't tell (Chrome, Electron apps).
- `scripts/release.sh`, and hidden CLI modes `--unload-cycle`, `--focus-check`, `--demo-card`, `--update-check`, `--update-stage`, `--update-install`.
- `docs/` with an agent guide, product, architecture (with ADRs 001–008), build, testing and privacy docs.
- MIT license; the repository is public.

### Changed
- **The model is freed after 15 idle minutes by default** (~0.7 GB back to the system). It reloads on the GPU the moment you press the key (0.4–0.6 s, while you speak). With Neural Engine on, the encoder is attached in the background after that dictation.
- **The recording pill uses ~2.4× less CPU**: Core Animation bars at 30 fps instead of redrawing at 60 fps. It looks the same.
- The microphone permission text no longer says “right ⌥” (the default key is Fn).
- The built-in dictionary test stores hashes of the banned names, not the names.

## 2026-11-10

### Added
- One main window with a sidebar (Home, Statistics, Dictionary, Settings). It opens when you launch the app again, or from the menu (`cb1ad77`).
- Home page: how-to, permission warnings with fix buttons, quick stats, and a feed of everything dictated grouped by day (search, copy, fix, delete).
- A Settings page that mirrors the menu-bar Settings submenu.
- Tests: `scripts/test.sh` with unit, integration and app-binary tests (61 tests); `JTM_SUPPORT_DIR` to isolate data (`2f80507`).

### Fixed
- Auto-language counts words, not letters. Russian with long English terms was labelled English, so the next streamed piece was decoded as English (`2f80507`).
- Pause detection finds clear pauses in fluent speech. Before, long dictations were cut only at the forced 25 s mark (`2f80507`).

### Removed
- Separate welcome, history and statistics windows. They are replaced by the main window (`cb1ad77`).
- `logo_concepts.png` and unused code (`24044bd`).

### Security
- The dictated text is no longer written to the system log (`24044bd`).

## 2026-11-09

### Added
- Optional Neural Engine acceleration through a Core ML encoder. Waits are about 5× shorter on M1 (`481d490`).
- Speech is transcribed in pieces while you talk, so text is ready about 1 s after release (`5ea97e6`).
- Ideas from Handy:
  - the clipboard is restored after the target app reads it, and clipboard managers skip the dictated text;
  - Esc cancels;
  - hold-or-tap hands-free mode;
  - optional start/stop sounds;
  - microphone picker and muting the speakers while recording;
  - unloading the model after idle;
  - a secure-input warning (`e2a0576`).
- Stats dashboard: words, characters, speaking time, WPM, time saved, daily chart, apps, languages, streak (`1bd09e5`).

### Changed
- Calmer recording waveform (`8bc2527`). The overlay pill no longer has a rectangular shadow or border (`9d6489b`).

### Removed
- The separate language-detection pass, which made recognition about 1.6× slower (`5ea97e6`).

## 2026-11-08

### Added
- First version (`dcaa90d`):
  - push-to-talk dictation on Fn or right ⌥ with local whisper.cpp;
  - bundled large-v3-turbo model;
  - personal and built-in dictionaries;
  - learning from corrections;
  - model management.
- Recording overlay, dictation history and stable local signing (`6752b2e`).

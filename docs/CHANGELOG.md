---
audience: all
owner: Malashkin
updated: 2026-11-10
---

# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The app has no version tags yet, so entries are grouped by date.

## [Unreleased]

### Added
- `docs/` with an agent guide, product, architecture (with ADRs), build, testing and privacy docs.

### Changed
- The microphone permission text no longer says «правый ⌥» (the default key is Fn).

## 2026-11-10

### Added
- One main window with a sidebar (Главная, Статистика, Словарь, Настройки). It opens when you launch the app again, or from the menu (`c4b7e80`).
- Home page: how-to, permission warnings with fix buttons, quick stats, and a feed of everything dictated grouped by day (search, copy, fix, delete).
- A Settings page that mirrors the menu-bar «Настройки».
- Tests: `scripts/test.sh` with unit, integration and app-binary tests (61 tests); `JTM_SUPPORT_DIR` to isolate data (`eae1325`).

### Fixed
- Auto-language counts words, not letters. Russian with long English terms was labelled English, so the next streamed piece was decoded as English (`eae1325`).
- Pause detection finds clear pauses in fluent speech. Before, long dictations were cut only at the forced 25 s mark (`eae1325`).

### Removed
- Separate welcome, history and statistics windows. They are replaced by the main window (`c4b7e80`).
- `logo_concepts.png` and unused code (`8b57b02`).

### Security
- The dictated text is no longer written to the system log (`8b57b02`).

## 2026-11-09

### Added
- Optional Neural Engine acceleration through a Core ML encoder. Waits are about 5× shorter on M1 (`35ee64d`).
- Speech is transcribed in pieces while you talk, so text is ready about 1 s after release (`e537b5d`).
- Ideas from Handy:
  - the clipboard is restored after the target app reads it, and clipboard managers skip the dictated text;
  - Esc cancels;
  - hold-or-tap hands-free mode;
  - optional start/stop sounds;
  - microphone picker and muting the speakers while recording;
  - unloading the model after idle;
  - a secure-input warning (`ebe903e`).
- Stats dashboard: words, characters, speaking time, WPM, time saved, daily chart, apps, languages, streak (`5f54da6`).

### Changed
- Calmer recording waveform (`eb2b4a9`). The overlay pill no longer has a rectangular shadow or border (`4e548be`).

### Removed
- The separate language-detection pass, which made recognition about 1.6× slower (`e537b5d`).

## 2026-11-08

### Added
- First version (`62f6816`):
  - push-to-talk dictation on Fn or right ⌥ with local whisper.cpp;
  - bundled large-v3-turbo model;
  - personal and built-in dictionaries;
  - learning from corrections;
  - model management.
- Recording overlay, dictation history and stable local signing (`a53f253`).

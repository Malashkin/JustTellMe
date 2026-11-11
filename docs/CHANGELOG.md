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
- One main window with a sidebar (Главная, Статистика, Словарь, Настройки). It opens when you launch the app again, or from the menu (`cb1ad77`).
- Home page: how-to, permission warnings with fix buttons, quick stats, and a feed of everything dictated grouped by day (search, copy, fix, delete).
- A Settings page that mirrors the menu-bar «Настройки».
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

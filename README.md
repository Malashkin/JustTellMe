# JustTellMe

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M4-black)
[![Release](https://img.shields.io/github/v/release/Malashkin/JustTellMe)](https://github.com/Malashkin/JustTellMe/releases/latest)

> **Private, offline push-to-talk dictation for macOS.** Hold a key, speak, release — the text is typed into
> whatever app you are in. Runs entirely on your Mac with whisper.cpp (Metal / Neural Engine): no cloud,
> no account, no subscription. The interface follows the system language (English or Russian). Recognition is
> tuned for Russian with English terms mixed in, and works for English too.
> Light on the Mac: the model leaves memory when you are not dictating, and updates install themselves.

## Installation
1. Download `JustTellMe.zip` from the [latest release](https://github.com/Malashkin/JustTellMe/releases/latest) page and unzip it into Applications.
2. First launch: right-click → Open (the app is not notarized by Apple).
3. Allow the microphone and Accessibility — the main window shows what is missing.

After that, updates install from inside the app.

Local dictation for macOS (Apple Silicon): hold a key (Fn or right ⌥), speak, release — the text is pasted into the active field. Recognition runs entirely on the device with [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (Metal); the large-v3-turbo model is bundled with the app.

Documentation: [docs/](docs/AGENTS.md) — product, architecture and decisions (ADRs), build, tests, privacy, [CHANGELOG](docs/CHANGELOG.md).

## Features
- Push-to-talk on Fn (🌐) or right ⌥: hold it and speak; double-tap for hands-free dictation, one more press to finish (like Wispr Flow); Esc cancels
- Recognition in pieces while you speak: after you release the key the text appears in about a second
- Optional Neural Engine acceleration (Core ML encoder, a 1.2 GB download; macOS prepares the model once)
- Languages: Auto (Russian/English, English words stay in Latin script), Russian, English
- Interface in English or Russian, following the macOS language
- Main window (click the app icon or use the 🎙 menu → Open JustTellMe…):
  - **Home** — everything dictated, by day; search, copy (the whole entry or a part selected with the mouse, ⌘C), fix; today's numbers
  - **Notes**, **Tasks** and your own lists — entries by day with date and time, search, copying part of the text, deleting ticked entries; tasks have a Backlog/Done status, a due date and date filters; New List and Edit List… set a list's name, command words and type
  - **Statistics** — words, characters, speed, time saved, a per-day chart, apps, languages
  - **Dictionary** — prompt, personal dictionary and replacements; a built-in dictionary of popular English terms used in Russian speech
  - **Settings** — key, mode, language, microphone, model, Neural Engine, model unloading, sounds, muting, clipboard, open at login
- Pasting doesn't clobber the clipboard: its previous contents come back, and clipboard managers don't save the dictated text
- Voice lists: start a phrase with a command word — “Note: call the bank”, “Task: send the report” (on a Russian system «Заметка: позвонить в банк», «Задача: отправить отчёт») — and the text is saved to that list instead of being pasted. Words and lists are configurable, and you can create your own (“Idea” → “Ideas”)
- ⌃⌥V pastes the last dictation again (if the text went to the wrong place)
- If the cursor is not in a text field, a card appears with the text and a Copy button
- Easy on resources: the model (~0.7 GB) is unloaded after 15 idle minutes and reloads in half a second while you speak; the recording overlay barely uses the CPU
- Updates from GitHub once a day: installed in two clicks with a signature check, permissions are kept
- Correct and Remember… — learning from corrections (new words → dictionary, corrected fragments → replacements)
- Switching models: built-in, from a file, or downloaded from the menu
- Self-contained bundle: no Homebrew/Python needed on the target machine

## Build
Requirements (on the build machine only): Xcode Command Line Tools, cmake, git, curl.

```bash
./build.sh            # → dist/JustTellMe.app and dist/JustTellMe.zip
SKIP_ZIP=1 ./build.sh # without the zip
```

`build.sh` clones whisper.cpp at a pinned commit, applies the patch from `patches/` and downloads the model.

## Tests
```bash
scripts/test.sh                 # unit + integration (needs at least one ./build.sh)
JTM_SKIP_SLOW=1 scripts/test.sh # fast: no speech recognition and no update-archive checks
```
Tests run in a temporary folder (`JTM_SUPPORT_DIR`) and don't touch your history or dictionary. Results go to `TEST_RESULTS.md`.

## Installing your own build
1. Copy `dist/JustTellMe.app` to Applications.
2. Allow the microphone and enable JustTellMe in System Settings → Privacy & Security → Accessibility.
3. Without a stable signature (`scripts/make-signing-identity.sh`), after a rebuild remove JustTellMe from Accessibility and add it again (or `tccutil reset Accessibility com.justtellme.app`).

## Releasing a version
Bump `CFBundleShortVersionString` in `Resources/Info.plist`, move the CHANGELOG entries into the version's section, commit and push, then run `scripts/release.sh`: build, all tests, tag and a GitHub Release with `JustTellMe.zip`. Installed apps see the update within a day.

## Debug modes
The binary `JustTellMe.app/Contents/MacOS/JustTellMe` understands hidden flags (no UI, or with a test window):
`--transcribe file.wav [--lang] [--model] [--encoder] [--repeat N]`, `--stream file.wav` (measures the wait after “release”),
`--learn "recognised" "corrected"`, `--list-models`, `--audio-info [--test-mute]`, `--demo-paste "text"`,
`--demo-overlay [out.png]`, `--demo-window out-prefix` (PNGs of every page of the main window), `--demo-card out.png`, `--demo-note-card out.png`,
`--unload-cycle file.wav` (unloads and reloads the model), `--focus-check [seconds]` (whether a text field is focused),
`--update-check`, `--update-stage file.zip [--version X]`, `--update-install other/JustTellMe.app`.

Set `JTM_LANG=en` or `JTM_LANG=ru` to force the interface language.

## Structure
- `Sources/App` — Swift: menu, main window, hotkey, recording, streaming recognition, pasting, dictionaries, statistics, localization (`L10n.swift`)
- `Sources/Shim` — C wrapper around whisper.cpp
- `Resources` — Info.plist, icon, built-in dictionary and replacements, `en.lproj`/`ru.lproj` microphone prompt
- `patches` — patch for whisper.cpp
- `Tests` — tests (a small custom harness: only Command Line Tools on the machine, no XCTest)

Personal data (dictation history, lists and their entries, personal dictionary, replacements, downloaded models) is stored in `~/Library/Application Support/JustTellMe/` and never goes into the repository.

## License
[MIT](LICENSE). Third-party components: [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT),
[Whisper](https://github.com/openai/whisper) models (MIT), [Silero VAD](https://github.com/snakers4/silero-vad) (MIT).

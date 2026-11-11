---
audience: all
owner: Malashkin
updated: 2026-11-10
---

# JustTellMe — Agent & Contributor Guide

JustTellMe is a local push-to-talk dictation app for macOS on Apple Silicon. It replaces Wispr Flow.
You hold Fn (or right ⌥) and speak; when you release, the text is pasted where the cursor is.
Speech is recognised entirely on the Mac by whisper.cpp (large-v3-turbo). Russian and English work,
including Russian speech with English terms. It lives in the menu bar and has one main window.

## Documentation map

| Area | Audience | Path |
|---|---|---|
| What the app does, settings, user flows | product | [product/](product/index.md) |
| How it works: components, dictation pipeline, ADRs | all | [architecture/](architecture/index.md) |
| Build, signing, install, release | devops | [devops/](devops/index.md) |
| Test suite: how to run, what it covers | testing | [testing/](testing/index.md) |
| Privacy: data on disk, permissions, clipboard, logs | all | [security/](security/index.md) |
| Change history | all | [CHANGELOG.md](CHANGELOG.md) |

## Quick start

1. Once per machine: `scripts/make-signing-identity.sh` (stable signature, so macOS keeps permissions across rebuilds)
2. Build: `SKIP_ZIP=1 ./build.sh` → `dist/JustTellMe.app` (first run clones and builds whisper.cpp and downloads the 574 MB model)
3. Install: `ditto dist/JustTellMe.app /Applications/JustTellMe.app && open /Applications/JustTellMe.app`
4. Grant Microphone and Accessibility. The home page of the main window shows what's missing.

## Commands

| Task | Command |
|---|---|
| Build app + zip | `./build.sh` (→ `dist/JustTellMe.app`, `dist/JustTellMe.zip`) |
| Build app only | `SKIP_ZIP=1 ./build.sh` |
| Test (all, ~35 s) | `scripts/test.sh` (needs one `./build.sh` first) |
| Test (fast, ~9 s) | `JTM_SKIP_SLOW=1 scripts/test.sh` (skips the two speech-recognition tests) |
| Run from the build | `open dist/JustTellMe.app` |
| Logs of a running build | run `dist/JustTellMe.app/Contents/MacOS/JustTellMe 2> /tmp/jtm.log` directly. `NSLog` from the app does not show up in `log show`. |
| Lint / typecheck | none beyond `swiftc` (the build fails on type errors) |

Hidden CLI modes of the binary (same code paths as the app, no UI):
- `--transcribe file.wav [--lang auto|ru|en] [--model x.bin] [--encoder x-encoder.mlmodelc] [--repeat N] [--verbose]`
- `--stream file.wav` plays the file in real time through the streaming path and prints the wait after "release"
- `--learn "recognised" "corrected"` and `--list-models`
- `--audio-info [--test-mute]` and `--demo-paste "text"`
- `--demo-overlay [out.png]` and `--demo-window out-prefix` render the overlay or every page of the main window to PNG

`JTM_SUPPORT_DIR=/some/dir` makes the app use another data folder (the tests rely on this).

## Coding conventions

- Plain AppKit built in code: no nibs, no SwiftUI, no SwiftPM or Xcode project. `build.sh` compiles `Sources/App/*.swift` with `swiftc`.
- Match the surrounding style: short doc comments (`///`) on types and non-obvious functions, `NSStackView` layouts, closures for callbacks (`onChange`, `onFix`, …).
- User-facing text is Russian. Code, comments and commit messages are English.
- Preferences go through `Prefs` (`Sources/App/Settings.swift`). A setting appears both in the menu-bar «Настройки» submenu and on the Settings page (`SettingsPane`), so keep the two in sync.
- Pure logic (stats, text cleanup, cut points, learning, vocabulary) lives in `static func`s, so it can be unit-tested.
- Commit after each finished change and push to `github.com/Malashkin/JustTellMe`. End messages with the `Co-Authored-By` line.

## Do not edit / generated zones

| Path | Why |
|---|---|
| `vendor/whisper.cpp/` | Cloned by `build.sh` at a pinned commit. Change [`patches/whisper-jtm.patch`](../patches/whisper-jtm.patch) instead. |
| `build/`, `dist/`, `models/` | Build output and downloaded models (git-ignored) |
| `Resources/AppIcon.icns` | Generated from `Resources/AppIcon.svg` |
| `Resources/builtin_terms.txt`, `builtin_replacements.txt` | Shipped to **every** user. Never add client or personal names. A test enforces this. |

## Known gotchas

- **Accessibility lost after a rebuild.** With an ad-hoc signature, macOS forgets the grant. Use `scripts/make-signing-identity.sh`, or remove and re-add JustTellMe in Privacy & Security → Accessibility (`tccutil reset Accessibility com.justtellme.app`).
- **Neural Engine first load takes 13–25 min on M1.** macOS compiles the Core ML encoder once per binary, so it can happen again after each update. Dictation keeps working on the GPU meanwhile.
- **Fn may switch the keyboard layout.** If System Settings → Keyboard → "Press 🌐 key to" is not "Do Nothing", Fn also switches input or opens emoji. The home page warns about this.
- **8 GB Macs:** with Neural Engine on, expect about 1 GB more memory. The GPU path slows down 2–3× when Chrome or VS Code keep the GPU busy.
- **Screen capture of our windows** needs Screen Recording permission for the terminal. Use `--demo-window` to check layouts instead.
- `Paths.support` is a `static let`: set `JTM_SUPPORT_DIR` before anything touches `Paths`.

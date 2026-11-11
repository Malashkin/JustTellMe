---
audience: all
owner: Malashkin
updated: 2026-11-10
---

# Overview

A single-process AppKit app (`LSUIElement`, menu-bar only) built from `Sources/App/*.swift` with `swiftc`, plus a
C shim over a static whisper.cpp with Metal and Core ML. No nibs, no SwiftUI, no other dependencies.
The binary links only to system libraries, and `build.sh` checks this.

## Components

| File | Responsibility |
|---|---|
| `main.swift` | Entry point; hidden CLI modes (`--transcribe`, `--stream`, `--demo-window`, …) |
| `AppDelegate.swift` | State machine (loading/idle/recording/transcribing/error), menu-bar menu, wiring everything together |
| `Hotkey.swift` | `PushToTalkHotkey`: listen-only `CGEventTap` for Fn / right ⌥ down/up, Esc, combos (needs Accessibility) |
| `Audio.swift` | `Recorder`: a fresh `AVAudioEngine` per recording at the device rate, preferred mic, levels for the overlay; `AudioUtil` resampling to 16 kHz |
| `Streaming.swift` | `StreamingDictation`: cuts long speech into pieces at pauses and sends them to Whisper while you talk |
| `Transcriber.swift` | Serial queue around the shim: load/unload model (+ optional Core ML encoder), transcribe, hallucination cleanup, script-based language label |
| `Sources/Shim/vf_whisper.c` | `vf_load`, `vf_transcribe`, `vf_uses_coreml`, `vf_free` over whisper.cpp |
| `NeuralEngine.swift` | Download, unzip and prepare the Core ML encoder; status for the UI |
| `Vocabulary.swift` | Prompt, personal and built-in dictionary, replacement rules, casing of Latin terms |
| `Learning.swift` | `CorrectionLearner` (word diff → rules + terms); `Paths` (data folder) |
| `Paster.swift` | Clipboard round trip: lazy pasteboard promise, ⌘V, restore after the target app reads it |
| `History.swift` | `history.json` (newest first, 2000 max), change callback |
| `Stats.swift` | `DictationStats` (pure aggregates) and `StatsPane` (Статистика page) |
| `MainWindow.swift` | The main window: sidebar, `HomePane` (status, quick stats, feed) |
| `SettingsPane.swift` | Настройки page; `SettingsHost` protocol implemented by `AppDelegate` |
| `Windows.swift` | `VocabularyPane` (Словарь page), `CorrectionWindow` (fix and remember) |
| `Overlay.swift` | The recording pill and its waveform |
| `Settings.swift` | `Prefs`, CoreAudio helpers, `SystemMute`, `SecureInput` |
| `Models.swift` | Bundled, imported and downloaded models; the active model |

## Dictation pipeline

```mermaid
sequenceDiagram
    participant K as Hotkey (CGEventTap)
    participant A as AppDelegate
    participant R as Recorder
    participant S as StreamingDictation
    participant W as Transcriber (whisper.cpp)
    participant P as Paster
    K->>A: key down
    A->>R: start (fresh AVAudioEngine, chosen mic)
    A->>S: new session (language, prompt)
    loop every 0.5 s while recording
        A->>S: poll()
        S->>S: ≥8 s pending? find a pause (≥0.3 s, piece ≥5 s; forced at 25 s)
        S->>W: transcribe piece (prompt + last 150 chars of the previous piece)
    end
    K->>A: key up (or second tap in hands-free mode)
    A->>R: stop
    A->>S: finish → last piece
    S->>W: transcribe remainder
    W-->>S: text (cleanup, replacements, casing)
    S-->>A: joined text + language
    A->>A: History.add
    A->>P: insert (clipboard promise + ⌘V, restore after read)
```

Notes:
- Pieces run one at a time on the transcriber's serial queue. The language and prompt for a piece are decided on
  that queue, so they always see the previous piece's result. A piece that follows an English piece is decoded as English.
- `auto` decodes as Russian, with no separate detection pass. The language label comes from the script, counting words.
- With Neural Engine on, the encoder runs through Core ML (`JTM_COREML_ENCODER`). In that case the shorter
  audio-context trick is disabled, because Core ML encoders have a fixed 1500 context.

## Main window

```mermaid
flowchart LR
    MW[MainWindow<br/>sidebar] --> H[HomePane<br/>status · quick stats · feed]
    MW --> ST[StatsPane]
    MW --> V[VocabularyPane]
    MW --> SE[SettingsPane]
    SE -- SettingsHost --> AD[AppDelegate]
    HI[(History)] -- onChange --> MW
    AD -- appStatus --> H
```

## Data on disk

`~/Library/Application Support/JustTellMe/` (or `$JTM_SUPPORT_DIR`): `history.json`, `dictionary.txt`,
`replacements.txt`, `prompt.txt` (only when customised), `Models/` (downloaded models and Core ML encoders).
See [security/](../security/index.md).

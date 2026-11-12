---
audience: product
owner: Malashkin
updated: 2026-11-12
---

# Settings

Every setting is on the **Настройки** page of the main window and in the 🎙 → «Настройки» submenu.
Values are stored in `UserDefaults` (domain `com.justtellme.app`). Read them with `defaults read com.justtellme.app`.

| Setting | Key | Default | Notes |
|---|---|---|---|
| Dictation key | `hotkey` | `fn` | `fn` or `rightOption` |
| How the key works | `trigger` | `holdOrDoubleTap` | `holdOrDoubleTap`: a double tap means hands-free. `holdOrTap`: a single short tap means hands-free. `holdOnly`: hold only. |
| Language | `language` | `auto` | `auto` decodes as Russian (no detection pass). The label in history comes from the script. |
| Microphone | `micUID` | system default | CoreAudio device UID. Falls back to the system mic if that device is unplugged. |
| Model | `modelPath` | bundled large-v3-turbo | |
| Neural Engine | `neuralEngine` | off | Downloads `<model>-encoder.mlmodelc` into `Models/` |
| Unload model after idle | `unloadAfterMinutes` | `15` | `0` = never (keeps ~0.7 GB in memory), 5, 15 or 60 minutes. The model reloads on the GPU as soon as the key is pressed (under 1 s). |
| Start/stop sounds | `sounds` | on | System sounds Tink / Pop |
| Mute speakers while dictating | `muteWhileRecording` | off | Never unmutes speakers you had muted yourself |
| Restore clipboard | `restoreClipboard` | on | |
| Built-in dictionary | `builtinDictionary` | on | |
| Launch at login | (SMAppService) | off | May need approval in System Settings → Login Items |
| Check for updates daily | `checkUpdates` | on | Asks api.github.com for the latest release; `lastUpdateCheck` holds the time of the last check |

Internal keys: `statsPeriod` (last period chosen on Статистика) and `welcomeShown` (whether the window has opened on first launch).

---
audience: product
owner: Malashkin
updated: 2026-11-12
---

# Features

## Dictation

- **Hold to talk:** hold Fn (🌐) or right ⌥, speak, then release. The text is pasted at the cursor in any app.
- **Hands-free (double tap):** double-tap the key (two presses, the second within 0.4 s) and speak without holding it; one more press stops and transcribes. A red dot on the overlay shows this mode. Recording stops on its own after 5 minutes. A single stray tap does nothing. Other modes: «нажать один раз» (a single short tap starts hands-free) and «только удерживать».
- **Esc** cancels the recording, or the recognition if it is already running.
- **Overlay:** a pill at the bottom of the screen. A calm waveform shows recording; an orange animation shows recognition. It is drawn with Core Animation layers at 30 fps, about 2.4× less CPU than before.
- **Speed:** long speech is recognised in pieces while you talk, so the text appears about 1 s after release (Neural Engine) or 1–2 s (GPU), even after 30 s of speech.
- **Languages:** Auto (Russian and English, leaning towards Russian), Russian, or English. English terms in Russian speech stay in Latin ("pull request", not «пул реквест»).
- **Sounds** at start and end, **mute the speakers** while dictating, and **mic picker**. Each can be turned off or changed.

## Pasting

The text is pasted with ⌘V. Your clipboard is restored right after the target app reads it. The dictated text is marked so clipboard managers (Maccy, Raycast, Paste) don't save it. You can turn restoring off, and then the dictated text stays on the clipboard.

- **⌃⌥V pastes the last dictation again** where the cursor is now, e.g. when it went to the wrong field. Also in the menu: 🎙 → «Вставить последнее ещё раз». It works without extra permissions, and the key press never reaches the app you are in.
- **No text field?** If the cursor was not in a text field (Finder, the desktop, a list, a web page with nothing focused), a card «Курсор не в поле ввода?» shows the text with a «Скопировать» button for 12 s. When JustTellMe cannot tell (Chrome, Electron apps such as VS Code or Slack), it stays quiet rather than show the card for nothing. The text is always in the feed on Главная anyway.

## Main window

Click the app icon in Finder, Launchpad or the Dock, or use 🎙 → «Открыть JustTellMe…» (⌘O in the menu). While the window is open the app has a Dock icon.

| Page | What's there |
|---|---|
| **Главная** | How-to; warnings with a fix button (no mic or Accessibility, Wispr Flow running, 🌐 switches layout); today's words, speed, streak, time saved; everything dictated, grouped by day, with time and app. Search; double-click to copy; right-click to fix or delete; «Очистить всё…». |
| **Статистика** | Today / 7 / 30 days / all time: words, characters, dictations, speaking time, words per minute, time saved (typing at 40 wpm minus speaking time); words-per-day chart; apps; languages; streak |
| **Словарь** | Prompt, personal dictionary, personal replacements (`wrong => right`), on/off toggle for the read-only built-in dictionary |
| **Настройки** | All settings, see [settings.md](settings.md) |

## Getting better over time

- **Fix and remember** (right-click a phrase, or 🎙 → «Исправить последнюю фразу…»): you edit the text and JustTellMe learns from the edit. New Latin or capitalised words go into the dictionary; changed fragments of up to 4 words become replacements.
- **Built-in dictionary:** about 400 common English tech terms used in Russian speech, plus about 100 fixes.

## Memory

The model takes ~0.7 GB of memory. By default it is freed after 15 minutes without dictation and loaded again the moment you press the key: on the GPU that takes under a second, while you are still speaking. With Neural Engine on, the first dictation after a pause runs on the GPU, and the Neural Engine encoder is attached in the background right after it. Change it, or keep the model loaded, in Настройки → «Выгружать модель из памяти».

## Updates

Once a day JustTellMe asks GitHub whether a newer version is out (Настройки → Обновления; you can turn it off or «Проверить сейчас»). If there is one, Главная and the 🎙 menu offer «Установить…»: the app downloads it, checks the signature and restarts. The Microphone and Accessibility permissions stay.

## Models

- **Built in:** large-v3-turbo (q5_0, 574 MB).
- **More models:** add one from a file, or download it from the menu (🎙 → Модель).
- **Neural Engine acceleration (optional):**
  - about 5× faster on M1, and unaffected by other apps using the GPU;
  - one-time 1.2 GB download, then macOS prepares the model once (up to ~30 min).

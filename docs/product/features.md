---
audience: product
owner: Malashkin
updated: 2026-11-24
---

# Features

## Interface language

The interface follows the system language: English by default, Russian when Russian is the first preferred language in
macOS (System Settings → General → Language & Region). `JTM_LANG=en` or `JTM_LANG=ru` in the environment forces one.
UI names below are the English ones. Recognition does not depend on this: it is set by the Language setting.

## Dictation

- **Hold to talk:** hold Fn (🌐) or right ⌥, speak, then release. The text is pasted at the cursor in any app.
- **Hands-free (double tap):** double-tap the key (two presses, the second within 0.4 s) and speak without holding it; one more press stops and transcribes. A red dot on the overlay shows this mode. Recording stops on its own after 5 minutes. A single stray tap does nothing. Other modes: “Hold, or tap once” (a single short tap starts hands-free) and “Hold only”.
- **Esc** cancels the recording, or the recognition if it is already running.
- **Overlay:** a pill at the bottom of the screen. A calm waveform shows recording; an orange animation shows recognition. It is drawn with Core Animation layers at 30 fps, about 2.4× less CPU than before.
- **Speed:** long speech is recognised in pieces while you talk, so the text appears about 1 s after release (Neural Engine) or 1–2 s (GPU), even after 30 s of speech.
- **Languages:** Auto (Russian and English, leaning towards Russian), Russian, or English. English terms in Russian speech stay in Latin ("pull request", not a Cyrillic spelling such as «пул реквест»).
- **Sounds** at start and end, **mute the speakers** while dictating, and **mic picker**. Each can be turned off or changed.

## Pasting

The text is pasted with ⌘V. Your clipboard is restored right after the target app reads it. The dictated text is marked so clipboard managers (Maccy, Raycast, Paste) don't save it. You can turn restoring off, and then the dictated text stays on the clipboard.

- **⌃⌥V pastes the last dictation again** where the cursor is now, e.g. when it went to the wrong field. Also in the menu: 🎙 → Paste Last Again. It works without extra permissions, and the key press never reaches the app you are in.
- **No text field?** If the cursor was not in a text field (Finder, the desktop, a list, a web page with nothing focused), a “No text field?” card shows the text with a Copy button for 12 s. When JustTellMe cannot tell (Chrome, Electron apps such as VS Code or Slack), it stays quiet rather than show the card for nothing. The text is always in the feed on Home anyway.

## Voice lists

Start a dictation with a list's command word and the rest of the phrase goes to that list; nothing is pasted into the frontmost app. Out of the box there are two lists: **Notes** (“Note, buy milk.” saves “Buy milk.”) and **Tasks** (“Task: send the report”). On a Russian system they are **Заметки** and **Задачи**, with the command words «Заметка» and «Задача» («Заметка, купить молоко.» saves «Купить молоко.»). The default lists are created once, on the first start, in the interface language of that moment. A “Saved to “…”” card shows the text for 4 s with a button to open the list. Lists are not part of the Home feed or the stats.

- **Own lists.** “New List” in the sidebar asks for a name, command words separated by commas (“Idea, Thought”) and a kind: notes (plain entries) or tasks. “Edit List…” at the top of a list changes all three or deletes the list together with its entries (asks first). The default lists can be renamed, changed or deleted like any other list. A command word is one word and may belong to one list only.
- **Which phrases count.** Only the first word, as a whole word: “This is a note about the trip” is pasted as usual (on a Russian system so are «Это заметка про отпуск» and «Заметками займусь завтра»). A word of 6 letters or more may be one letter wrong, missing or extra, or split in two. On a Russian system the command word is «Заметка»; near misses such as «Замевка», «Заметко», «Зодача» (for «Задача») or «За метка» still count. Real Russian words one letter off («Заметна», «Заметкам», «Заметках», «Зачётка», «Намётка», «Задачам», «Задачах») never count. Shorter words (“Note”, “Task”, “Idea”) must be heard exactly. The command word alone saves nothing and beeps.
- **Every list** shows entries grouped by day with dated headers (“Today, November 23”, “Yesterday, November 22”, “Tomorrow, November 24”, then full dates), the date and time on each entry, search, ticks with “Check All” and “Delete N …”, right-click → Copy / Delete, and text you can select with the mouse and copy with ⌘C.
- **Tasks lists** add:
  - a status per task, Backlog or Done, from the menu in front of it, from “Done” / “To Backlog” for the ticked tasks, or from the right-click menu. Done tasks are struck through and remember when they were done.
  - a due date: “Due Date…” (calendar), “Clear Due Date”. The line under a task shows “Due Nov 25”, in red with “— overdue” when it has passed in Backlog, and “Done Nov 24, 10:04”.
  - filters: Status (All / Backlog / Done); Date — Created, Due or Done — over Today, 7 days, 30 days, All dates or “Custom range…” (from–to, both days included). Created and Done look back; Due looks ahead (due in the next 1/7/30 days) and always includes overdue tasks in Backlog. Entries are grouped by the chosen date; due dates soonest first, tasks without one last under “No due date”.

## Main window

Click the app icon in Finder, Launchpad or the Dock, or use 🎙 → Open JustTellMe… (⌘O in the menu). While the window is open the app has a Dock icon.

| Page | What's there |
|---|---|
| **Home** | How-to; warnings with a fix button (no mic or Accessibility, Wispr Flow running, 🌐 switches layout); today's words, speed, streak, time saved; everything dictated, grouped by day, with time and app. Select any part of the text with the mouse and press ⌘C; ⌘C on highlighted rows or a double click on the time copies the whole entry. Search; right-click to fix or delete; “Clear All…”. |
| **Notes**, **Tasks**, own lists | One page per voice list (see above), in the sidebar after Home, followed by “New List”. |
| **Statistics** | Today / 7 days / 30 days / All time: words, characters, dictations, speaking time, words per minute, time saved (typing at 40 wpm minus speaking time); words-per-day chart; apps; languages; streak |
| **Dictionary** | Prompt, personal dictionary, personal replacements (`wrong => right`), on/off toggle for the read-only built-in dictionary |
| **Settings** | All settings, see [settings.md](settings.md) |

## Getting better over time

- **Fix and remember** (right-click a phrase, or 🎙 → Correct Last Phrase…): you edit the text and JustTellMe learns from the edit. New Latin or capitalised words go into the dictionary; changed fragments of up to 4 words become replacements.
- **Built-in dictionary:** about 400 common English tech terms used in Russian speech, plus about 100 fixes.

## Memory

The model takes ~0.7 GB of memory. By default it is freed after 15 minutes without dictation and loaded again the moment you press the key: on the GPU that takes under a second, while you are still speaking. With Neural Engine on, the first dictation after a pause runs on the GPU, and the Neural Engine encoder is attached in the background right after it. Change it, or keep the model loaded, in Settings → “Unload model from memory”.

## Updates

Once a day JustTellMe asks GitHub whether a newer version is out (Settings → Updates; you can turn it off or press “Check Now”). If there is one, Home and the 🎙 menu offer “Install…”: the app downloads it, checks the signature and restarts. The Microphone and Accessibility permissions stay.

## Models

- **Built in:** large-v3-turbo (q5_0, 574 MB).
- **More models:** add one from a file, or download it from the menu (🎙 → Model).
- **Neural Engine acceleration (optional):**
  - about 5× faster on M1, and unaffected by other apps using the GPU;
  - one-time 1.2 GB download, then macOS prepares the model once (up to ~30 min).

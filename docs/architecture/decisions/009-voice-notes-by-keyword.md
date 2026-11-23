---
audience: all
owner: Malashkin
updated: 2026-11-23
---

# 009. Voice notes: the word «Заметка» at the start, saved instead of pasted

**Status:** Accepted (2026-11-23)

## Context
Some things you say are not meant for the app in front of you: a reminder, an idea, a task. They should be kept
in JustTellMe and found later, without switching to a notes app.

## Decision
- A dictation whose **first word** is «Заметка» (any case, followed by a space, punctuation or nothing) is a note.
  The word anywhere else, or as part of a longer word («Заметками»), does not count: false triggers would swallow
  ordinary dictation, which is worse than saying the word again.
- The rest of the phrase is saved to `notes.json`; nothing is pasted. A «Заметка сохранена» card confirms it,
  because the text did not appear where the cursor is. «Заметка» alone saves nothing and beeps.
- Notes are a separate store, not a flag on `HistoryEntry`: they are not part of the Главная feed or the stats,
  and deleting history does not delete notes.
- Detection runs on the final text (`NoteCommand.body`), after cleanup and replacements, so it needs no change to
  the streaming pipeline.

## Consequences
- The keyword is fixed and Russian; there is no setting for it yet.
- If the recogniser mishears the first word, the phrase is pasted as usual and stays in the history.

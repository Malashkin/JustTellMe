---
audience: all
owner: Malashkin
updated: 2026-11-24
---

# 009. Voice notes: the word «Заметка» at the start, saved instead of pasted

**Status:** Accepted (2026-11-23), extended by [ADR 010](010-configurable-voice-lists.md): the word and the list are now configurable

## Context
At the time the interface and the command word were Russian only; today the default word is “Note” on an English
system and «Заметка» on a Russian one ([ADR 010](010-configurable-voice-lists.md), [ADR 011](011-interface-follows-system-language.md)).
The Russian examples below are speech, i.e. what the recogniser hears.

Some things you say are not meant for the app in front of you: a reminder, an idea, a task. They should be kept
in JustTellMe and found later, without switching to a notes app.

## Decision
- A dictation whose **first word** is «Заметка» (any case, followed by a space, punctuation or nothing) is a note.
  The word anywhere else, or as part of a longer word («Заметками»), does not count: false triggers would swallow
  ordinary dictation, which is worse than saying the word again.
- The recogniser sometimes mishears the word («Замевка», «За мефка»). The first word, or the first two words joined
  when the first is at most 3 letters, matches when it is at most one edit (Levenshtein) from «заметка». Real words
  one edit away are listed in `NoteCommand.lookalikes` and never match. Two edits would also catch «заметкой»,
  «заметно» and «пометка», which start ordinary sentences.
- The rest of the phrase is saved to `notes.json`; nothing is pasted. A “Note saved” card («Заметка сохранена») confirms it,
  because the text did not appear where the cursor is. «Заметка» alone saves nothing and beeps.
- Notes are a separate store, not a flag on `HistoryEntry`: they are not part of the Home feed or the stats,
  and deleting history does not delete notes.
- Detection runs on the final text (`NoteCommand.body`), after cleanup and replacements, so it needs no change to
  the streaming pipeline.

## Consequences
- The keyword is fixed and Russian; there is no setting for it yet (made configurable by ADR 010).
- If the recogniser gets the first word more than one letter wrong, the phrase is pasted as usual and stays in the history.
- A new real word one letter off «заметка» that starts ordinary sentences must be added to `lookalikes`.

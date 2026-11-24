---
audience: all
owner: Malashkin
updated: 2026-11-24
---

# 010. Voice lists: own names and command words, notes or tasks

**Status:** Accepted (2026-11-24). Extends [ADR 009](009-voice-notes-by-keyword.md).

## Context
After voice notes, the next asks were tasks (“Task …”, «Задача …» in Russian, with Backlog/Done, a deadline and date
filters), other command words instead of «Заметка», and new pages in the sidebar for them (“Idea” → Ideas).

## Decision
- **One concept, two kinds.** A voice list has a name, one or more one-word command words and a kind: notes (plain
  entries) or tasks (status, done time, deadline, filters). Notes and Tasks (Заметки and Задачи on a Russian
  system, command words “Note”/“Task” or «Заметка»/«Задача») are the two lists created on the first start; they can be renamed, changed or deleted like any other. A kind can be changed later; task fields are kept.
- **Storage.** `lists.json` keeps the lists in sidebar order; each list's entries are in `list-<id>.json`, one
  `ListItem` type for both kinds. Deleting a list deletes its file after a confirmation. Notes from the earlier
  `notes.json` are moved into the first default list once, when `lists.json` does not exist yet.
- **Matching.** Each command word goes through `SpokenKeyword` (ADR 009). Words of 6 letters or more accept one
  edit; shorter words must be exact, because one letter turns «идея» (idea) into «идеи» (ideas) or «идем» (we go); “Note” and “Task” are exact too. Built-in lookalike
  lists (real Russian words one letter off) exist for «заметка» and «задача». An exact word beats a near miss of another list; otherwise the first list
  in the sidebar wins. The editor refuses a word already used by another list and multi-word commands.
- **Editing in place.** “New List” is a sidebar row; “Edit List…” is on each list's page. No separate settings
  section: the words are next to the entries they collect.
- **Tasks filters.** Status, which date (Created / Due / Done) and a period. Created and Done look back;
  Due looks ahead and always shows overdue Backlog tasks, so “7 days” on Due is “what to do this week”.

## Consequences
- A user word one letter away from a common word (like «заметна» next to «заметка») can catch ordinary phrases; only built-in words
  have lookalike lists. Removing the word or making it longer is the fix.
- Multi-word commands (“Shopping list”) are not supported.

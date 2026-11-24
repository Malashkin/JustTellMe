---
audience: all
owner: Malashkin
updated: 2026-11-24
---

# 011. The interface follows the system language (English or Russian)

**Status:** Accepted (2026-11-24)

## Context
The interface was Russian only. The app is public, and English-speaking users should get an English interface,
while Russian speakers keep the Russian one. There are only two languages, and the app is built with plain `swiftc`
from `build.sh` (no Xcode project, no asset catalogs, no `genstrings`/`.strings` build step for the code).

## Decision
- **Pairs next to the code.** Every user-facing string is written as `tr("English", "Русский")`
  (`Sources/App/L10n.swift`). `tr` returns the Russian text when `L10n.isRussian`, otherwise the English one.
  Counts use `L10n.plural` (English one/other, Russian one/few/many), dates use `L10n.formatter(en:ru:)`, a cached
  `DateFormatter` with the matching locale and pattern. No `.strings` files for the code: with two languages the
  pair is easier to keep in sync than a key in two files, and the build needs no extra step.
- **Which language.** Russian when the first entry of `Locale.preferredLanguages` is Russian, English otherwise.
  `JTM_LANG=en|ru` in the environment forces one (tests, screenshots via `--demo-window`).
- **Default voice lists** are created on the first start in the current language: Notes/Tasks with the command words
  “Note”/“Task” in English, Заметки/Задачи with «Заметка»/«Задача» in Russian (`VoiceLists.defaultLists`).
  Existing lists are user data and are never renamed when the language changes.
- **Microphone prompt.** macOS shows `NSMicrophoneUsageDescription` itself, so it can't go through `tr`. It is in
  `Resources/en.lproj/InfoPlist.strings` and `Resources/ru.lproj/InfoPlist.strings`, which `build.sh` copies into
  the bundle.
- **Speech data stays Russian.** The default Whisper prompt, the hallucination phrases removed after recognition,
  the built-in replacements and the lookalike word lists for «заметка»/«задача» describe what the recogniser hears
  in Russian speech, not interface text, so they are not translated.

## Consequences
- Adding a string means writing both languages at once; a missing translation is visible in review as a one-argument
  call that doesn't compile.
- The tests run with the Russian interface (`scripts/test.sh` sets `JTM_LANG=ru`, `Tests/main.swift` sets
  `L10n.isRussian = true`), so existing assertions on Russian texts and default lists keep working.
  `Tests/LocalizationTests.swift` switches to English and checks texts, plurals, dates and the default lists.
- A third language would need a different mechanism (e.g. `.strings` files or a table keyed by language).

---
audience: all
owner: Malashkin
updated: 2026-11-11
---

# Architecture decisions (ADRs)

Each record explains one choice that isn't obvious from the code. Up: [architecture](../index.md).

| ADR | Decision | Status |
|---|---|---|
| [001](001-local-whisper-cpp.md) | Recognise locally with a static whisper.cpp, model bundled | Accepted |
| [002](002-stream-while-speaking.md) | Transcribe in pieces while the user speaks | Accepted |
| [003](003-optional-neural-engine.md) | Neural Engine (Core ML encoder) as an opt-in setting | Accepted |
| [004](004-plain-test-executable.md) | Tests as a plain executable, not XCTest | Accepted |
| [005](005-single-main-window.md) | One main window instead of separate windows | Accepted |
| [006](006-unload-when-idle.md) | Free the model after 15 idle minutes, reload on the GPU first | Accepted |
| [007](007-updates-from-github-releases.md) | Updates from GitHub Releases, installed and verified by the app | Accepted |
| [008](008-keep-pauses-inside-a-clip.md) | Cut pauses inside a clip before recognition | Rejected |

---
audience: all
owner: Malashkin
updated: 2026-11-10
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

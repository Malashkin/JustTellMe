---
audience: testing
owner: Malashkin
updated: 2026-11-10
---

# 004. Tests as a plain executable

**Status:** Accepted (2026-11-10)

## Context
The build machine has only Command Line Tools, with no Xcode, so there is no XCTest or `swift test` for a swiftc-only
project. We still wanted unit tests plus integration tests against real files and the real binary.

## Decision
- `scripts/test.sh` compiles the app sources without `main.swift`, together with `Tests/*.swift`, into `build/JustTellMeTests`.
- `Tests/Harness.swift` is a ~60-line harness: `T.test`, `T.eq`, `T.ok`, and a seeded RNG for property tests.
- Every run uses a fresh temporary `JTM_SUPPORT_DIR`.

## Consequences
- The tests need no extra tooling and run in about 35 s, or about 9 s with `JTM_SKIP_SLOW=1`.
- There is no IDE integration, coverage or mutation tool. Mutation testing was done with a script that applies hand-picked mutants.
- If Xcode becomes available, the tests can move to XCTest. Assertions are thin wrappers, so this is a mechanical change.

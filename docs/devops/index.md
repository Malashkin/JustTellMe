---
audience: devops
owner: Malashkin
updated: 2026-11-10
---

# Build & release

How to build, sign, install and hand JustTellMe to another Mac. Up: [AGENTS.md](../AGENTS.md).

## Requirements (build machine only)

Apple Silicon, macOS 13 or later, Xcode Command Line Tools, cmake, git and curl. The target Mac needs nothing extra.

## What `build.sh` does

```mermaid
flowchart TD
    A[Clone whisper.cpp at pinned commit] --> B[Apply patches/whisper-jtm.patch]
    B --> C[cmake: static libs, Metal embedded, Core ML, Accelerate BLAS, no OpenMP]
    C --> D[Download / verify model 574 MB + Silero VAD]
    D --> E[swiftc Sources/App + shim → build/JustTellMe]
    E --> F[Assemble dist/JustTellMe.app]
    F --> G[codesign: 'JustTellMe Local Signing' or ad-hoc]
    G --> H[Check: only system dylibs linked]
    H --> I[ditto zip → dist/JustTellMe.zip<br/>unless SKIP_ZIP=1]
```

- The whisper.cpp commit, model name, size and VAD checksum are pinned at the top of `build.sh`.
- The model is reused from `models/` or `build/model/` when the size matches.
- The patch adds `whisper_set_audio_ctx`, Core ML only on request (`JTM_COREML_ENCODER`), and `whisper_uses_coreml()`. It is applied only if missing.

## Signing

Run `scripts/make-signing-identity.sh` once. It creates a self-signed "JustTellMe Local Signing" identity in the login
keychain. With it, macOS keeps the Accessibility and Microphone grants across rebuilds. Without it, `build.sh` signs
ad-hoc, and you need to re-grant Accessibility after every build. Override the identity with `SIGN_ID=...`.

## Install / update

```bash
osascript -e 'quit app "JustTellMe"'
rm -rf /Applications/JustTellMe.app && ditto dist/JustTellMe.app /Applications/JustTellMe.app
open /Applications/JustTellMe.app
```

After an update:
- If the home page says Accessibility is missing, remove JustTellMe with «−» and add it again.
- With Neural Engine on, macOS may prepare the encoder again (15–25 min in the background).

## Another Mac

Copy `dist/JustTellMe.zip`, unzip it into Applications, then right-click → Open. The app is not notarized.
Then grant Microphone and Accessibility.

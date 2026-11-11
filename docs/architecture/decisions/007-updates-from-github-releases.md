---
audience: all
owner: Malashkin
updated: 2026-11-11
---

# 007. Updates from GitHub Releases, installed by the app

**Status:** Accepted (2026-11-11)

## Context
New versions were copied to other Macs by hand as `dist/JustTellMe.zip`. The repository is public now. The app is
signed with a self-signed certificate («JustTellMe Local Signing»), not notarized. Sparkle would add a framework, an
EdDSA key and an appcast for a single-maintainer app.

## Decision
- A release is a GitHub Release `vX.Y.Z` with `JustTellMe.zip`, made by `scripts/release.sh` (build, tests, tag, upload).
- The app asks `api.github.com/repos/Malashkin/JustTellMe/releases/latest` at most once a day (`checkUpdates`, on by
  default; the request carries only a `User-Agent: JustTellMe/<version>`).
- Install: download with `URLSession` (no quarantine flag, so no Gatekeeper prompt), unpack with `ditto`, then refuse
  unless: same bundle id; version equals the release tag; `codesign --verify --deep --strict` passes; the new app
  satisfies the running app's designated requirement (same certificate). Ad-hoc developer builds skip the last check.
- A shell script waits for the app to quit, swaps the bundle (rolling back on failure) and opens it. The restart waits
  while recording or transcribing.

## Consequences
- The same certificate keeps the Microphone and Accessibility grants across updates.
- Trust rests on GitHub (HTTPS) plus the certificate check: a release signed with another certificate is refused.
- If the app's folder is not writable, the release page is opened instead.
- Releases must be built on the machine with the signing certificate.

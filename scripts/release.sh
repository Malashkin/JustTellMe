#!/bin/bash
# Publish the current version as a GitHub Release: build with the zip, run all tests, tag vX.Y.Z and
# upload dist/JustTellMe.zip with the matching CHANGELOG section as notes. Installed apps pick it up
# from there (Sources/App/Updater.swift).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
die() { echo "release: $*" >&2; exit 1; }

V=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
TAG="v$V"
[ -z "$(git status --porcelain)" ] || die "uncommitted changes"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "HEAD is not pushed to origin/main"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG exists"
gh release view "$TAG" >/dev/null 2>&1 && die "release $TAG exists"
security find-identity -p codesigning 2>/dev/null | grep -q '"JustTellMe Local Signing"' \
  || die "no 'JustTellMe Local Signing' identity: installed apps would refuse this build"

NOTES=$(mktemp)
awk -v v="$V" '$0 ~ "^## \\[" v "\\]" {on=1; next} on && /^## / {exit} on {print}' docs/CHANGELOG.md > "$NOTES"
[ -s "$NOTES" ] || die "no '## [$V]' section in docs/CHANGELOG.md"

./build.sh
scripts/test.sh

git tag -a "$TAG" -m "JustTellMe $V"
git push -q origin "$TAG"
gh release create "$TAG" dist/JustTellMe.zip --title "JustTellMe $V" --notes-file "$NOTES"
rm -f "$NOTES"
echo "released $TAG"

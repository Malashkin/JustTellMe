#!/bin/bash
# Runs the JustTellMe tests: unit + integration (real files, real app binary).
# The machine has only Command Line Tools (no XCTest), so the tests are a plain executable built from
# the app sources with Tests/main.swift instead of Sources/App/main.swift.
#
#   scripts/test.sh                 # everything (needs ./build.sh to have been run once)
#   JTM_SKIP_SLOW=1 scripts/test.sh # skip the two speech-recognition tests (~1 min)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
WSRC="$ROOT/vendor/whisper.cpp"
WBUILD="$WSRC/build-static"
BUILD="$ROOT/build"
[ -f "$WBUILD/src/libwhisper.a" ] && [ -f "$BUILD/obj/vf_whisper.o" ] || { echo "Run ./build.sh first (it builds whisper.cpp)"; exit 2; }

APP_SOURCES=()
for f in "$ROOT"/Sources/App/*.swift; do [ "$(basename "$f")" = "main.swift" ] || APP_SOURCES+=("$f"); done

echo "==> Compiling tests"
swiftc -Onone -target arm64-apple-macos13.0 \
  -import-objc-header "$ROOT/Sources/Shim/vf_whisper.h" \
  "${APP_SOURCES[@]}" "$ROOT"/Tests/*.swift \
  "$BUILD/obj/vf_whisper.o" \
  "$WBUILD/src/libwhisper.a" "$WBUILD/src/libwhisper.coreml.a" \
  "$WBUILD/ggml/src/libggml.a" "$WBUILD/ggml/src/libggml-base.a" "$WBUILD/ggml/src/libggml-cpu.a" \
  "$WBUILD/ggml/src/ggml-blas/libggml-blas.a" "$WBUILD/ggml/src/ggml-metal/libggml-metal.a" \
  -lc++ \
  -framework Cocoa -framework AVFoundation -framework ServiceManagement \
  -framework Metal -framework MetalKit -framework Foundation -framework Accelerate -framework CoreML \
  -o "$BUILD/JustTellMeTests"

# Never touch the user's real history/dictionary/models.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/jtm-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "==> Running tests"
JTM_SUPPORT_DIR="$TMP" \
JTM_RESOURCES="$ROOT/Resources" \
JTM_APP_BIN="${JTM_APP_BIN:-$ROOT/dist/JustTellMe.app/Contents/MacOS/JustTellMe}" \
  "$BUILD/JustTellMeTests"

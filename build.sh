#!/bin/bash
# Reproducible build of JustTellMe.app (Apple Silicon, macOS 13+).
# Requirements on the BUILD machine only: Xcode Command Line Tools, cmake, git, curl.
# The resulting .app is self-contained (whisper.cpp static, Metal shaders embedded, model bundled).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

WHISPER_REPO="https://github.com/ggml-org/whisper.cpp.git"
WHISPER_COMMIT="6a8addd258eadd6563f8c582e8acc535e6325364"
MODEL_NAME="ggml-large-v3-turbo-q5_0.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME"
MODEL_SIZE=574041195

WSRC="$ROOT/vendor/whisper.cpp"
WBUILD="$WSRC/build-static"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$DIST/JustTellMe.app"
EXE="JustTellMe"
MIN_OS="13.0"

log() { printf '\n==> %s\n' "$*"; }

# 1. whisper.cpp source
if [ ! -d "$WSRC/.git" ]; then
  log "Cloning whisper.cpp"
  mkdir -p "$ROOT/vendor"
  git clone "$WHISPER_REPO" "$WSRC"
fi
if [ "$(git -C "$WSRC" rev-parse HEAD)" != "$WHISPER_COMMIT" ]; then
  log "Checking out whisper.cpp $WHISPER_COMMIT"
  git -C "$WSRC" fetch --depth 1 origin "$WHISPER_COMMIT" || git -C "$WSRC" fetch origin
  git -C "$WSRC" checkout -q "$WHISPER_COMMIT"
fi
# Small local patch: public whisper_set_audio_ctx() so language detection can use a short encoder window.
if ! grep -q whisper_set_audio_ctx "$WSRC/include/whisper.h"; then
  log "Applying patches"
  git -C "$WSRC" apply "$ROOT/patches/whisper-set-audio-ctx.patch"
fi

# 2. whisper.cpp static libs (Metal on, shaders embedded, no OpenMP => no libomp dylib)
log "Building whisper.cpp (static, Metal)"
cmake -S "$WSRC" -B "$WBUILD" -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
  -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_OS" >/dev/null
cmake --build "$WBUILD" -j"$(sysctl -n hw.ncpu)" --target whisper >/dev/null

# 3. Model
MODEL="$BUILD/model/$MODEL_NAME"
mkdir -p "$BUILD/model"
size_of() { stat -f %z "$1" 2>/dev/null || echo 0; }
if [ "$(size_of "$MODEL")" != "$MODEL_SIZE" ]; then
  if [ "$(size_of "$ROOT/models/$MODEL_NAME")" = "$MODEL_SIZE" ]; then
    cp "$ROOT/models/$MODEL_NAME" "$MODEL"
  else
    log "Downloading model"
    curl -L --fail -o "$MODEL.part" "$MODEL_URL"
    mv "$MODEL.part" "$MODEL"
  fi
fi
[ "$(size_of "$MODEL")" = "$MODEL_SIZE" ] || { echo "Model size mismatch"; exit 1; }

# VAD model (Silero v6.2.0 converted to ggml, ~0.9 MB). Bundled with a .vad extension so it is
# never listed as a selectable whisper model.
VAD="$BUILD/model/ggml-silero-v6.2.0.bin"
VAD_SHA="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"
if [ "$(shasum -a 256 "$VAD" 2>/dev/null | cut -d' ' -f1)" != "$VAD_SHA" ]; then
  log "Downloading VAD model"
  curl -L --fail -o "$VAD" "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"
  [ "$(shasum -a 256 "$VAD" | cut -d' ' -f1)" = "$VAD_SHA" ] || { echo "VAD checksum mismatch"; exit 1; }
fi

# 4. Compile
log "Compiling JustTellMe"
mkdir -p "$BUILD/obj"
clang -c -O2 -arch arm64 -mmacosx-version-min="$MIN_OS" \
  -I"$WSRC/include" -I"$WSRC/ggml/include" \
  "$ROOT/Sources/Shim/vf_whisper.c" -o "$BUILD/obj/vf_whisper.o"

LIBS=(
  "$WBUILD/src/libwhisper.a"
  "$WBUILD/ggml/src/libggml.a"
  "$WBUILD/ggml/src/libggml-base.a"
  "$WBUILD/ggml/src/libggml-cpu.a"
  "$WBUILD/ggml/src/ggml-blas/libggml-blas.a"
  "$WBUILD/ggml/src/ggml-metal/libggml-metal.a"
)

swiftc -O -target "arm64-apple-macos$MIN_OS" \
  -import-objc-header "$ROOT/Sources/Shim/vf_whisper.h" \
  "$ROOT"/Sources/App/*.swift \
  "$BUILD/obj/vf_whisper.o" "${LIBS[@]}" \
  -lc++ \
  -framework Cocoa -framework AVFoundation -framework ServiceManagement \
  -framework Metal -framework MetalKit -framework Foundation -framework Accelerate \
  -o "$BUILD/$EXE"

# 5. Bundle
log "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$EXE" "$APP/Contents/MacOS/$EXE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$MODEL" "$APP/Contents/Resources/$MODEL_NAME"
cp "$VAD" "$APP/Contents/Resources/ggml-silero-v6.2.0.vad"
cp "$ROOT/Resources/builtin_terms.txt" "$ROOT/Resources/builtin_replacements.txt" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 6. Ad-hoc sign
log "Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

# 7. Verify no third-party dylib deps
log "Linked libraries"
otool -L "$APP/Contents/MacOS/$EXE"
if otool -L "$APP/Contents/MacOS/$EXE" | tail -n +2 | grep -vE '^\s*(/usr/lib/|/System/Library/)'; then
  echo "ERROR: non-system dylib dependency found"; exit 1
fi

# 8. Zip for transfer (ditto keeps bundle metadata)
log "Zipping"
if [ "${SKIP_ZIP:-0}" = "1" ]; then log "Done (zip skipped): $APP"; exit 0; fi
rm -f "$DIST/JustTellMe.zip"
ditto -c -k --keepParent "$APP" "$DIST/JustTellMe.zip"
ls -lh "$DIST"
log "Done: $APP"

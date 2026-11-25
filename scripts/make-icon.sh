#!/bin/bash
# Regenerates Resources/AppIcon.icns from Resources/AppIcon.svg (macOS 13+).
# Renders every iconset size with NSImage, which keeps transparency but ignores SVG filters,
# and packs them with iconutil.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/Resources/AppIcon.svg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/render.swift" <<'SWIFT'
import Cocoa
let a = CommandLine.arguments
guard let src = NSImage(contentsOfFile: a[1]) else { fatalError("cannot read \(a[1])") }
let px = Int(a[3])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.imageInterpolation = .high
src.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
SWIFT
swiftc -O "$WORK/render.swift" -o "$WORK/render"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  "$WORK/render" "$SVG" "$SET/icon_${s}x${s}.png" "$s"
  "$WORK/render" "$SVG" "$SET/icon_${s}x${s}@2x.png" "$((s * 2))"
done
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
echo "Wrote $ROOT/Resources/AppIcon.icns"

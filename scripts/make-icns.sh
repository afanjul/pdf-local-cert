#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from the master logo.
# Run after editing Resources/logo/pdf-local-cert-logo.png, then rebuild the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

SRC="Resources/logo/pdf-local-cert-logo.png"
OUT="Resources/AppIcon.iconset"
rm -rf "$OUT"; mkdir -p "$OUT"

sips -z 1024 1024 "$SRC" --out /tmp/icon-master-1024.png >/dev/null
M=/tmp/icon-master-1024.png
sips -z 16  16  "$M" --out "$OUT/icon_16x16.png"      >/dev/null
sips -z 32  32  "$M" --out "$OUT/icon_16x16@2x.png"   >/dev/null
sips -z 32  32  "$M" --out "$OUT/icon_32x32.png"      >/dev/null
sips -z 64  64  "$M" --out "$OUT/icon_32x32@2x.png"   >/dev/null
sips -z 128 128 "$M" --out "$OUT/icon_128x128.png"    >/dev/null
sips -z 256 256 "$M" --out "$OUT/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$M" --out "$OUT/icon_256x256.png"    >/dev/null
sips -z 512 512 "$M" --out "$OUT/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$M" --out "$OUT/icon_512x512.png"    >/dev/null
cp "$M"             "$OUT/icon_512x512@2x.png"

iconutil -c icns "$OUT" -o Resources/AppIcon.icns
rm -rf "$OUT"
echo "✓ Resources/AppIcon.icns"

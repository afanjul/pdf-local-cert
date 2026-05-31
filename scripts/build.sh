#!/usr/bin/env bash
# Build PDF Local Cert.app: Rust sidecar + SwiftUI shell, assembled and code-signed.
#
# Usage:
#   scripts/build.sh                 # ad-hoc signed (local run)
#   SIGN_ID="Apple Development: …"  scripts/build.sh
#   SIGN_ID="Developer ID Application: …" NOTARIZE=1 scripts/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="PDF Local Cert"
EXEC_NAME="PDFLocalCert"
BUNDLE="build/${APP_NAME}.app"
SIGN_ID="${SIGN_ID:--}"            # default: ad-hoc
CARGO="${CARGO:-/opt/homebrew/bin/cargo}"

echo "▸ Building Rust sidecar (release)…"
( cd core && CARGO_NET_GIT_FETCH_WITH_CLI=true "$CARGO" build --release )

echo "▸ Building SwiftUI shell (release)…"
swift build -c release

echo "▸ Assembling ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Helpers" "$BUNDLE/Contents/Resources"

cp ".build/release/PDFLocalCert"            "$BUNDLE/Contents/MacOS/${EXEC_NAME}"
cp "core/target/release/pdflocalcert-core"  "$BUNDLE/Contents/Helpers/pdflocalcert-core"
cp "Resources/Info.plist"                "$BUNDLE/Contents/Info.plist"
cp "Resources/AppIcon.icns"              "$BUNDLE/Contents/Resources/AppIcon.icns"
cp "Resources/drop-icon-base.png"        "$BUNDLE/Contents/Resources/drop-icon-base.png"
cp "Resources/drop-icon-pen.png"         "$BUNDLE/Contents/Resources/drop-icon-pen.png"
# Localized strings (NSLocalizedString reads these from the bundle's .lproj dirs).
for lproj in Resources/*.lproj; do
    cp -R "$lproj" "$BUNDLE/Contents/Resources/"
done

echo "▸ Code signing (id: ${SIGN_ID})…"
ENT="Resources/PDFLocalCert.entitlements"
codesign --force --options runtime --timestamp=none \
    --sign "$SIGN_ID" "$BUNDLE/Contents/Helpers/pdflocalcert-core"
codesign --force --options runtime --timestamp=none \
    --entitlements "$ENT" \
    --sign "$SIGN_ID" "$BUNDLE/Contents/MacOS/${EXEC_NAME}"
codesign --force --options runtime --timestamp=none \
    --entitlements "$ENT" \
    --sign "$SIGN_ID" "$BUNDLE"

echo "▸ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$BUNDLE" || true

echo "✓ Built: $ROOT/$BUNDLE"

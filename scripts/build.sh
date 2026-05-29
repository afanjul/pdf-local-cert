#!/usr/bin/env bash
# Build PDF-Signer.app: Rust sidecar + SwiftUI shell, assembled and code-signed.
#
# Usage:
#   scripts/build.sh                 # ad-hoc signed (local run)
#   SIGN_ID="Apple Development: …"  scripts/build.sh
#   SIGN_ID="Developer ID Application: …" NOTARIZE=1 scripts/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="PDF-Signer"
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

cp ".build/release/PDFSigner"            "$BUNDLE/Contents/MacOS/${APP_NAME}"
cp "core/target/release/pdfsigner-core"  "$BUNDLE/Contents/Helpers/pdfsigner-core"
cp "Resources/Info.plist"                "$BUNDLE/Contents/Info.plist"

echo "▸ Code signing (id: ${SIGN_ID})…"
ENT="Resources/PDFSigner.entitlements"
codesign --force --options runtime --timestamp=none \
    --sign "$SIGN_ID" "$BUNDLE/Contents/Helpers/pdfsigner-core"
codesign --force --options runtime --timestamp=none \
    --entitlements "$ENT" \
    --sign "$SIGN_ID" "$BUNDLE/Contents/MacOS/${APP_NAME}"
codesign --force --options runtime --timestamp=none \
    --entitlements "$ENT" \
    --sign "$SIGN_ID" "$BUNDLE"

echo "▸ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$BUNDLE" || true

echo "✓ Built: $ROOT/$BUNDLE"

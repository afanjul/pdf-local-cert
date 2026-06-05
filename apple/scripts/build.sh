#!/usr/bin/env bash
# Build PDF Local Cert.app: Rust sidecar + SwiftUI shell, assembled and code-signed.
#
# Monorepo layout: the shared Rust core lives at <repo>/core; the Apple shell
# (this script, Package.swift, Sources/, Resources/) lives under <repo>/apple.
#
# Usage:
#   apple/scripts/build.sh                 # ad-hoc signed (local run)
#   SIGN_ID="Apple Development: …"  apple/scripts/build.sh
#   SIGN_ID="Developer ID Application: …" NOTARIZE=1 apple/scripts/build.sh
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # <repo>/apple
REPO_ROOT="$(cd "$APPLE_ROOT/.." && pwd)"        # <repo>
cd "$APPLE_ROOT"

APP_NAME="PDF Local Cert"
EXEC_NAME="PDFLocalCert"
BUNDLE="$APPLE_ROOT/build/${APP_NAME}.app"
CORE_DIR="$REPO_ROOT/core"
SIGN_ID="${SIGN_ID:--}"            # default: ad-hoc
CARGO="${CARGO:-/opt/homebrew/bin/cargo}"

echo "▸ Building Rust sidecar (release)…"
( cd "$CORE_DIR" && CARGO_NET_GIT_FETCH_WITH_CLI=true "$CARGO" build --release )

echo "▸ Building SwiftUI shell (release)…"
swift build -c release

echo "▸ Assembling ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Helpers" "$BUNDLE/Contents/Resources"

cp "$APPLE_ROOT/.build/release/PDFLocalCert"        "$BUNDLE/Contents/MacOS/${EXEC_NAME}"
cp "$CORE_DIR/target/release/pdflocalcert-core"     "$BUNDLE/Contents/Helpers/pdflocalcert-core"
cp "$APPLE_ROOT/Resources/Info.plist"               "$BUNDLE/Contents/Info.plist"
cp "$APPLE_ROOT/Resources/AppIcon.icns"             "$BUNDLE/Contents/Resources/AppIcon.icns"
cp "$APPLE_ROOT/Resources/drop-icon-base.png"       "$BUNDLE/Contents/Resources/drop-icon-base.png"
cp "$APPLE_ROOT/Resources/drop-icon-pen.png"        "$BUNDLE/Contents/Resources/drop-icon-pen.png"
# Localized strings (NSLocalizedString reads these from the bundle's .lproj dirs).
for lproj in "$APPLE_ROOT"/Resources/*.lproj; do
    cp -R "$lproj" "$BUNDLE/Contents/Resources/"
done

echo "▸ Code signing (id: ${SIGN_ID})…"
ENT="$APPLE_ROOT/Resources/PDFLocalCert.entitlements"
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

echo "✓ Built: $BUNDLE"

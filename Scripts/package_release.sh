#!/usr/bin/env bash
set -euo pipefail
#
# Package Ollie (Mac) into a NOTARIZED, downloadable .dmg.
#
# Why notarized direct-download instead of the Mac App Store / TestFlight: the app uses
# a global hotkey (Capture/HotKeyManager.swift) + Accessibility, which cannot run in the
# App Sandbox — and App Store / TestFlight Mac builds REQUIRE the sandbox. So we ship a
# Developer ID-signed, notarized app that anyone can download and run (Gatekeeper-
# approved), no App Store, no sandbox, all features intact.
#
# Pipeline: build_app.sh (release: Developer ID + hardened runtime + embedded profile)
#   -> stage the .app with an Applications drop-link -> hdiutil .dmg -> sign the .dmg
#   -> notarytool submit --wait -> stapler staple -> dist/Ollie.dmg.
#
# ONE-TIME credential setup (stores YOUR App Store Connect API key in the login
# keychain; this script only references the profile NAME, never the secret):
#   xcrun notarytool store-credentials HN_NOTARY \
#     --key ~/Downloads/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
#
# Env knobs: NOTARY_PROFILE (default HN_NOTARY), DEV_ID (Developer ID identity),
#            BUILD_DIR (default ~/Library/Caches/...), SKIP_NOTARIZE=1 (sign-only).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NOTARY_PROFILE="${NOTARY_PROFILE:-HN_NOTARY}"
DEV_ID="${DEV_ID:-Developer ID Application: Mohammad Shobaki (2J5S7H2LTB)}"
APP_NAME="Ollie"
DIST_DIR="$ROOT_DIR/dist"
FINAL_DMG="$DIST_DIR/Ollie.dmg"

# SwiftPM's SQLite build DB throws "disk I/O error" when .build sits on the iCloud-
# synced repo path, so build OUTSIDE iCloud (also avoids codesign xattr re-stamp races
# on cloud-backed files).
export BUILD_DIR="${BUILD_DIR:-$HOME/Library/Caches/HandheldNotes-build}"

STAGE_ROOT="$(mktemp -d)"          # stage + assemble the image on a clean (non-iCloud) FS
STAGE="$STAGE_ROOT/dmg"
DMG_PATH="$STAGE_ROOT/Ollie.dmg"
cleanup() { rm -rf "$STAGE_ROOT"; }
trap cleanup EXIT

echo "==> Building + signing the release app (BUILD_DIR=$BUILD_DIR)…"
APP_BUNDLE="$(BUILD_CONFIG=release HC_SIGN=release "$SCRIPT_DIR/build_app.sh" | tail -1)"
[ -d "$APP_BUNDLE" ] || { echo "ERROR: app bundle not found ($APP_BUNDLE)"; exit 1; }
echo "    app: $APP_BUNDLE"
echo "    sig: $(codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E 'Authority=Developer ID|flags=' | head -2 | tr '\n' ' ')"

echo "==> Staging .dmg contents (with an Applications drop-link)…"
mkdir -p "$STAGE"
cp -R "$APP_BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
xattr -cr "$STAGE" 2>/dev/null || true

echo "==> Creating compressed .dmg…"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null

echo "==> Signing the .dmg with Developer ID…"
codesign --force --sign "$DEV_ID" "$DMG_PATH"

if [ -n "${SKIP_NOTARIZE:-}" ]; then
  echo "==> SKIP_NOTARIZE set — signed .dmg only (Gatekeeper will warn until it's notarized)."
else
  echo "==> Notarizing (submitting to Apple; waits for the verdict, ~1-5 min)…"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> Stapling the notarization ticket…"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo "==> Publishing to $FINAL_DMG…"
mkdir -p "$DIST_DIR"
cp "$DMG_PATH" "$FINAL_DMG"

echo ""
echo "==> Done: $FINAL_DMG"
if [ -z "${SKIP_NOTARIZE:-}" ]; then
  echo "    Notarized — testers download it, open it, and drag Ollie to Applications; no Gatekeeper block."
fi

#!/usr/bin/env bash
set -euo pipefail

# Builds Handheld Notes into a real, launchable .app bundle and signs it with a
# stable Developer ID identity (so macOS permission grants persist across builds,
# the same reasoning as the old app's build_app.sh). Prints the bundle path last.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-debug}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build}"
APP_NAME="Handheld Notes"
APP_BUNDLE="$BUILD_DIR/${BUILD_CONFIG}/${APP_NAME}.app"
EXECUTABLE="$BUILD_DIR/${BUILD_CONFIG}/HandheldNotes"
ENTITLEMENTS="$ROOT_DIR/HandheldNotes.entitlements"

strip_distribution_xattrs() {
  # Deep clean: the SwiftPM-generated resource .bundle carries com.apple.FinderInfo,
  # which makes codesign refuse to seal the nested bundle ("resource fork … not
  # allowed" / "code has no resources"). Strip the whole tree, then belt-and-braces
  # remove the two stubborn xattrs from every directory.
  xattr -cr "$APP_BUNDLE" 2>/dev/null || true
  find "$APP_BUNDLE" -print0 2>/dev/null | while IFS= read -r -d '' f; do
    xattr -d com.apple.FinderInfo "$f" 2>/dev/null || true
    xattr -d "com.apple.fileprovider.fpfs#P" "$f" 2>/dev/null || true
  done
  find "$APP_BUNDLE" -name '.DS_Store' -delete 2>/dev/null || true
}

cd "$ROOT_DIR"
swift build -c "$BUILD_CONFIG" --build-path "$BUILD_DIR"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/HandheldNotes"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# SwiftPM emits resources as a HandheldNotes_HandheldNotes.bundle next to the
# executable. Copy it into the app bundle so the demo audio resolves at runtime.
RES_BUNDLE="$BUILD_DIR/${BUILD_CONFIG}/HandheldNotes_HandheldNotes.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
  cp -R "$RES_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi
if [[ -f "$ROOT_DIR/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi
strip_distribution_xattrs

# Prefer a stable Developer ID identity; fall back to ad-hoc if none is installed.
if [[ -z "${CODE_SIGN_IDENTITY:-}" ]]; then
  CODE_SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
fi

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  echo "Signing with stable identity: $CODE_SIGN_IDENTITY"
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$CODE_SIGN_IDENTITY" "$APP_BUNDLE"
else
  echo "WARNING: ad-hoc signing — no stable identity found; permission grants won't persist across rebuilds."
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

strip_distribution_xattrs

echo "$APP_BUNDLE"

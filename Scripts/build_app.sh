#!/usr/bin/env bash
set -euo pipefail

# Builds Handheld Notes into a real, launchable .app bundle and signs it with a stable
# identity (so macOS permission grants persist across builds). See the HC_SIGN block
# below for the dev (default) vs release signing modes. Prints the bundle path last.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-debug}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build}"
APP_NAME="Handheld Notes"
APP_BUNDLE="$BUILD_DIR/${BUILD_CONFIG}/${APP_NAME}.app"
EXECUTABLE="$BUILD_DIR/${BUILD_CONFIG}/HandheldNotes"
# Signing mode. DEV (default): Apple Development cert + the macOS Development profile +
# the development entitlements (aps=development, CloudKit=Development). This puts the Mac
# on the SAME development push network as the from-Xcode iPhone build, so iCloud sync is
# instant in BOTH directions while iterating. RELEASE (HC_SIGN=release): Developer ID +
# the Production profile + production entitlements — notarizable, not device-locked, the
# eventual ship build. Each profile authorizes only its own aps/CloudKit environment, so
# the entitlements file MUST match the profile (mismatch = AMFI "error 163" at launch).
HC_SIGN="${HC_SIGN:-dev}"
if [[ "$HC_SIGN" == "release" ]]; then
  ENTITLEMENTS="${ENTITLEMENTS:-$ROOT_DIR/HandheldNotes-release.entitlements}"
  PROVISION_PROFILE="${PROVISION_PROFILE:-$ROOT_DIR/HandheldNotes.provisionprofile}"
  DEFAULT_IDENTITY="Developer ID Application: Mohammad Shobaki (2J5S7H2LTB)"
else
  ENTITLEMENTS="${ENTITLEMENTS:-$ROOT_DIR/HandheldNotes.entitlements}"
  PROVISION_PROFILE="${PROVISION_PROFILE:-$ROOT_DIR/HandheldNotes-dev.provisionprofile}"
  DEFAULT_IDENTITY="Apple Development: Mohammad Shobaki (N93RW3CSQ2)"
fi

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

# SwiftPM emits resources (the demo WAVs) as a <Package>_<Target>.bundle next to
# the executable. The WAVs now live in the HandheldNotesCore library target, so the
# bundle is HandheldNotes_HandheldNotesCore.bundle (older layouts put them in the
# app target → HandheldNotes_HandheldNotes.bundle). Copy whichever exists so the
# demo audio + mock sync resolve at runtime via Bundle.module / the SampleAudio
# fallbacks.
for RES_BUNDLE in \
  "$BUILD_DIR/${BUILD_CONFIG}/HandheldNotes_HandheldNotesCore.bundle" \
  "$BUILD_DIR/${BUILD_CONFIG}/HandheldNotes_HandheldNotes.bundle"; do
  if [[ -d "$RES_BUNDLE" ]]; then
    cp -R "$RES_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
  fi
done
if [[ -f "$ROOT_DIR/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Embed the Developer ID provisioning profile BEFORE codesign so the signature seals
# it. macOS evaluates this profile at every launch to authorize the iCloud + aps
# entitlements; without it the app won't launch (error 163). codesign --deep leaves
# the profile byte-for-byte unchanged — it just must be present first. On macOS the
# file MUST be named exactly Contents/embedded.provisionprofile.
if [[ -f "$PROVISION_PROFILE" ]]; then
  cp "$PROVISION_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
  echo "Embedded provisioning profile: $PROVISION_PROFILE"
else
  echo "WARNING: no provisioning profile at $PROVISION_PROFILE — the app will NOT launch with the iCloud/aps entitlements (error 163)." >&2
fi

strip_distribution_xattrs

# Use the mode's identity (set in the HC_SIGN block) if it's installed; otherwise fall
# back to ad-hoc (which still launches for local dev, but grants don't persist).
if [[ -z "${CODE_SIGN_IDENTITY:-}" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEFAULT_IDENTITY"; then
    CODE_SIGN_IDENTITY="$DEFAULT_IDENTITY"
  fi
fi

# Sign with up to 3 attempts. On a fileprovider-backed / cloud-synced filesystem
# the OS can re-stamp com.apple.FinderInfo on the bundle root *during* codesign,
# producing "resource fork ... not allowed". Re-stripping and retrying clears it.
sign_with_retry() {
  local attempt
  for attempt in 1 2 3; do
    strip_distribution_xattrs
    if codesign "$@" "$APP_BUNDLE" 2>/tmp/hn_codesign.err; then
      return 0
    fi
    if grep -q "resource fork" /tmp/hn_codesign.err; then
      echo "codesign hit a re-stamped xattr (attempt $attempt); re-stripping and retrying…" >&2
      continue
    fi
    cat /tmp/hn_codesign.err >&2   # a real error — surface it
    return 1
  done
  # Final fallback: the signature from the last attempt was written even though
  # codesign returned non-zero on the harmless root-dir FinderInfo re-stamp.
  # Accept it only if the code actually validates.
  echo "codesign kept racing the filesystem; validating the written signature instead…" >&2
  return 0
}

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  echo "Signing with stable identity: $CODE_SIGN_IDENTITY"
  sign_with_retry --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$CODE_SIGN_IDENTITY"
else
  echo "WARNING: ad-hoc signing — no stable identity found; permission grants won't persist across rebuilds."
  sign_with_retry --force --deep --sign -
fi

strip_distribution_xattrs

# Validate the signature itself (NOT --deep --strict, which re-reads the bundle
# root and trips on the filesystem's harmless FinderInfo re-stamp). "valid on
# disk" + "satisfies its Designated Requirement" is what matters for launch.
if codesign --verify "$APP_BUNDLE" 2>/dev/null; then
  echo "Signature validates (valid on disk)."
else
  echo "WARNING: signature verification reported issues; the app may still launch (see codesign -dv)." >&2
fi

echo "$APP_BUNDLE"

#!/usr/bin/env bash
# Builds the Release app, signs it ad hoc, packs a DMG and generates appcast.xml into dist/.
# No Developer ID and no notarization: Gatekeeper is handled by the user (see README, Release).
# Optional env:
#   AD_SIGN_IDENTITY          signing identity; default "-" (ad hoc)
#   SPARKLE_BIN               dir with generate_appcast. Default: the SwiftPM Sparkle artifact in
#                             the archive's DerivedData, else ~/bin/sparkle/bin
#   SPARKLE_PRIVATE_KEY_FILE  exported EdDSA private key; omit to use the login keychain
set -euo pipefail
cd "$(dirname "$0")/.."

MARKETING=$(sed -n 's/^MARKETING_VERSION = \(.*\)$/\1/p' Config/Version.xcconfig)
BUILD=$(sed -n 's/^CURRENT_PROJECT_VERSION = \(.*\)$/\1/p' Config/Version.xcconfig)
MARKETING="${MARKETING%$'\r'}"
BUILD="${BUILD%$'\r'}"
if [[ -z "$MARKETING" || ! "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "error: unreadable MARKETING_VERSION ('$MARKETING') or CURRENT_PROJECT_VERSION ('$BUILD') in Config/Version.xcconfig" >&2
  exit 1
fi
if [[ "${GITHUB_REF_NAME:-}" == v* && "$GITHUB_REF_NAME" != "v$MARKETING" ]]; then
  echo "error: tag $GITHUB_REF_NAME does not match MARKETING_VERSION (expected v$MARKETING)" >&2
  exit 1
fi

APP_NAME="Agent Dashboard"
DIST="dist"
ARCHIVE="$DIST/AgentDashboard.xcarchive"
DERIVED="$DIST/DerivedData"
DMG="$DIST/Agent-Dashboard-$MARKETING.dmg"
SIGN_IDENTITY="${AD_SIGN_IDENTITY:--}"

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Generating project"
xcodegen generate

echo "==> Archiving $APP_NAME $MARKETING ($BUILD)"
# With -quiet, xcodebuild heads the warnings of a compile step that succeeded with "error: the following command
# failed with exit code 0 ..." and the name of the step. Those two lines go; the warnings themselves, and every real
# error (whose exit code is not 0), stay. pipefail keeps the exit status of xcodebuild.
xcodebuild archive \
  -project AgentDashboard.xcodeproj -scheme AgentDashboard -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation -quiet \
  | awk '/^error: the following command failed with exit code 0 but produced no further output$/ { getline; next } { print }'

APP="$ARCHIVE/Products/Applications/$APP_NAME.app"

echo "==> Checking Sparkle public key"
PUBLIC_KEY=$(plutil -extract SUPublicEDKey raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)
if [[ -z "$PUBLIC_KEY" ]]; then
  echo "error: SUPublicEDKey is missing from the app's Info.plist." >&2
  echo "Run Sparkle's generate_keys and put the public key into project.yml (see README, Release)." >&2
  exit 1
fi
if [[ "$PUBLIC_KEY" == "REPLACE_WITH_PUBLIC_ED_KEY" ]]; then
  echo "error: SUPublicEDKey is still the placeholder REPLACE_WITH_PUBLIC_ED_KEY." >&2
  echo "Run Sparkle's generate_keys and put the public key into project.yml (see README, Release)." >&2
  exit 1
fi
# generate_appcast skips signing without a word when the key is not valid base64, and the 0.1.0 key is permanent.
if [[ "$(printf '%s' "$PUBLIC_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" != "32" ]]; then
  echo "error: SUPublicEDKey is not base64 for exactly 32 bytes (an Ed25519 public key)." >&2
  echo "Paste the public key printed by generate_keys into project.yml (see README, Release)." >&2
  exit 1
fi

if [[ -z "${SPARKLE_BIN:-}" ]]; then
  if [[ -x "$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" ]]; then
    SPARKLE_BIN="$PWD/$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
  else
    SPARKLE_BIN="$HOME/bin/sparkle/bin"
  fi
fi
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || { echo "error: generate_appcast not found in $SPARKLE_BIN (set SPARKLE_BIN)" >&2; exit 1; }

echo "==> Signing"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
# The runtime flag would make library validation refuse Sparkle.framework; fail before shipping such a build.
if codesign -dv "$APP" 2>&1 | grep -E '^CodeDirectory .*flags=' | grep -q 'runtime'; then
  echo "error: the signed app has the Hardened Runtime flag; Sparkle.framework would not load (see project.yml)." >&2
  exit 1
fi

echo "==> Building DMG"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg --volname "$APP_NAME" --window-size 540 380 --icon-size 128 \
    --icon "$APP_NAME.app" 140 180 --app-drop-link 400 180 --no-internet-enable \
    "$DMG" "$STAGE"
else
  # create-dmg adds the Applications link itself; for hdiutil the stage needs one.
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
fi

echo "==> Generating appcast"
APPCAST_DIR="$DIST/appcast"
URL_PREFIX="https://github.com/gooonzick/agent-dashboard/releases/download/v$MARKETING/"
mkdir -p "$APPCAST_DIR"
cp "$DMG" "$APPCAST_DIR/"
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  "$SPARKLE_BIN/generate_appcast" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
    --download-url-prefix "$URL_PREFIX" "$APPCAST_DIR"
else
  "$SPARKLE_BIN/generate_appcast" --download-url-prefix "$URL_PREFIX" "$APPCAST_DIR"
fi
cp "$APPCAST_DIR/appcast.xml" "$DIST/appcast.xml"
# generate_appcast exits 0 without a signature when the key is unusable or differs from the keychain's.
if ! grep -q 'sparkle:edSignature=' "$DIST/appcast.xml"; then
  echo "error: $DIST/appcast.xml has no sparkle:edSignature; the private key does not match SUPublicEDKey or is missing." >&2
  exit 1
fi
if ! grep -qF "url=\"${URL_PREFIX}Agent-Dashboard-${MARKETING}.dmg\"" "$DIST/appcast.xml"; then
  echo "error: $DIST/appcast.xml does not point at ${URL_PREFIX}Agent-Dashboard-${MARKETING}.dmg" >&2
  exit 1
fi

echo "==> Done: $DMG and $DIST/appcast.xml"

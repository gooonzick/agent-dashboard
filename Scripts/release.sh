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
xcodebuild archive \
  -project AgentDashboard.xcodeproj -scheme AgentDashboard -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation -quiet

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
mkdir -p "$APPCAST_DIR" && cp "$DMG" "$APPCAST_DIR/"
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  "$SPARKLE_BIN/generate_appcast" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
    --download-url-prefix "$URL_PREFIX" "$APPCAST_DIR"
else
  "$SPARKLE_BIN/generate_appcast" --download-url-prefix "$URL_PREFIX" "$APPCAST_DIR"
fi
cp "$APPCAST_DIR/appcast.xml" "$DIST/appcast.xml"

echo "==> Done: $DMG and $DIST/appcast.xml"

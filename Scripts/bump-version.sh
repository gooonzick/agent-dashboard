#!/usr/bin/env bash
# Usage: Scripts/bump-version.sh 0.2.0   (marketing version; the build number goes up by one)
# Optional env: VERSION_XCCONFIG overrides the file to rewrite (for dry runs).
set -euo pipefail
cd "$(dirname "$0")/.."
XCCONFIG="${VERSION_XCCONFIG:-Config/Version.xcconfig}"
NEW_MARKETING="${1:-}"
if [[ ! "$NEW_MARKETING" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: bump-version.sh <X.Y.Z>" >&2
  exit 1
fi
CURRENT_BUILD=$(sed -n 's/^CURRENT_PROJECT_VERSION = \([0-9]*\)$/\1/p' "$XCCONFIG")
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || { echo "error: unreadable CURRENT_PROJECT_VERSION in $XCCONFIG" >&2; exit 1; }
NEXT_BUILD=$((CURRENT_BUILD + 1))
printf 'MARKETING_VERSION = %s\nCURRENT_PROJECT_VERSION = %s\n' "$NEW_MARKETING" "$NEXT_BUILD" >| "$XCCONFIG"
echo "Version $NEW_MARKETING ($NEXT_BUILD)"

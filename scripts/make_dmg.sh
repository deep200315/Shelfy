#!/usr/bin/env bash
# Wraps build/Shelfy.app into a drag-to-Applications DMG and a zip (release artifacts).
# Uses only built-in tools (hdiutil, ditto) so CI needs no extra installs.
#
#   scripts/make_dmg.sh    → build/Shelfy-<version>.dmg and build/Shelfy-<version>.zip
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/Shelfy.app"
[[ -d "$APP" ]] || { echo "ERROR: $APP not found; run scripts/package_app.sh first" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$ROOT/build/Shelfy-$VERSION.dmg"
ZIP="$ROOT/build/Shelfy-$VERSION.zip"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG" "$ZIP"
hdiutil create -volname "Shelfy $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Created $DMG"
echo "Created $ZIP"

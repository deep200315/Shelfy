#!/bin/sh
# Installs (or updates) Shelfy from the latest GitHub release.
#
#   curl -fsSL https://deep200315.github.io/Shelfy/install.sh | sh
#
# Files fetched with curl aren't quarantined, so macOS doesn't show the "Open Anyway" prompt that
# browser downloads of free (non-notarized) apps get. Read this script before running it:
# it only downloads Shelfy.dmg from GitHub, copies Shelfy.app into Applications, and opens it.
set -eu

REPO="deep200315/Shelfy"
DMG_URL="https://github.com/$REPO/releases/latest/download/Shelfy.dmg"
DEST="${SHELFY_INSTALL_DIR:-/Applications}"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }

[ "$(uname -s)" = "Darwin" ] || { echo "Shelfy is a macOS app." >&2; exit 1; }

WORK=$(mktemp -d)
MOUNT="$WORK/mount"
cleanup() {
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

say "Downloading the latest Shelfy"
curl -fSL --progress-bar -o "$WORK/Shelfy.dmg" "$DMG_URL"

say "Installing into $DEST"
mkdir -p "$MOUNT"
hdiutil attach -nobrowse -readonly -quiet -mountpoint "$MOUNT" "$WORK/Shelfy.dmg"
if pgrep -xq Shelfy; then
  osascript -e 'quit app "Shelfy"' 2>/dev/null || pkill -x Shelfy || true
  sleep 1
fi
rm -rf "$DEST/Shelfy.app"
ditto "$MOUNT/Shelfy.app" "$DEST/Shelfy.app"
# An older copy installed from a browser download may still carry the quarantine flag.
xattr -dr com.apple.quarantine "$DEST/Shelfy.app" 2>/dev/null || true

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DEST/Shelfy.app/Contents/Info.plist")
say "Shelfy $VERSION installed. Opening it: look for the stacked-photos icon in your menu bar."
[ -n "${SHELFY_NO_OPEN:-}" ] || open "$DEST/Shelfy.app"

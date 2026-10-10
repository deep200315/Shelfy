#!/usr/bin/env bash
# Builds Shelfy.app into ./build (adapted from the macos-spm-app-packaging skill template).
#
#   scripts/package_app.sh [release|debug]
#
# Env:
#   ARCHES        Architectures to build, e.g. "arm64 x86_64" for a universal app (default: host arch)
#   APP_IDENTITY  Developer ID Application identity; when unset the app is ad-hoc signed
#   VERSION       Overrides the version (default: latest git tag, else version.env)
set -euo pipefail

CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP_NAME=Shelfy
BUNDLE_ID=com.deeptanush.shelfy
MACOS_MIN_VERSION=14.0
APP_IDENTITY=${APP_IDENTITY:-}

# Version: the git tag is the source of truth; version.env is the fallback for untagged builds.
source "$ROOT/version.env"
TAG_VERSION=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)
MARKETING_VERSION=${VERSION:-${TAG_VERSION:-$MARKETING_VERSION}}
# Monotonic build number (Sparkle and macOS compare CFBundleVersion).
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)

ARCH_LIST=( ${ARCHES:-$(uname -m)} )
STAGING="$ROOT/.build/package"
rm -rf "$STAGING"
for ARCH in "${ARCH_LIST[@]}"; do
  swift build -c "$CONF" --arch "$ARCH"
  # Newer toolchains share one products folder across arches, so copy each binary out right away.
  mkdir -p "$STAGING/$ARCH"
  cp "$(swift build -c "$CONF" --arch "$ARCH" --show-bin-path)/$APP_NAME" "$STAGING/$ARCH/$APP_NAME"
done

APP="$ROOT/build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Deeptanush Kapaka. MIT License.</string>
    <key>NSDesktopFolderUsageDescription</key><string>Shelfy collects new screenshots saved to your Desktop.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Shelfy can collect new files from folders you choose to watch.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Shelfy can collect new files from folders you choose to watch.</string>
    <key>GitCommit</key><string>${GIT_COMMIT}</string>
</dict>
</plist>
PLIST

BINARIES=()
for ARCH in "${ARCH_LIST[@]}"; do
  BINARIES+=("$STAGING/$ARCH/$APP_NAME")
done
DEST="$APP/Contents/MacOS/$APP_NAME"
if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
  lipo -create "${BINARIES[@]}" -output "$DEST"
else
  cp "${BINARIES[0]}" "$DEST"
fi
chmod +x "$DEST"

# Verify the binary contains exactly the requested architectures.
ACTUAL=$(lipo -archs "$DEST")
for ARCH in "${ARCH_LIST[@]}"; do
  [[ "$ACTUAL" == *"$ARCH"* ]] || { echo "ERROR: $DEST missing arch $ARCH (have: $ACTUAL)" >&2; exit 1; }
done

# App icon, generated once from the SF Symbol script if missing.
if [[ ! -f Resources/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
  rm -rf build/AppIcon.iconset
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Strip extended attributes so the code signature seals cleanly.
chmod -R u+w "$APP"
xattr -cr "$APP"

if [[ -z "$APP_IDENTITY" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" "$APP"
fi

echo "Created $APP (v$MARKETING_VERSION, build $BUILD_NUMBER, ${ARCH_LIST[*]})"

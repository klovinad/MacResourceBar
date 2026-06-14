#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MacResourceBar"
PROJECT_NAME="NetworkMenuMonitor.xcodeproj"
SCHEME="NetworkMenuMonitor"
CONFIGURATION="Release"
BUILD_DIR="build-release"
RELEASE_DIR="Release"
VERSION="1.0"
APP_BUNDLE="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
STAGING_DIR="$BUILD_DIR/dmg-staging"
DMG_TEMP="$BUILD_DIR/$APP_NAME-temp.dmg"
DMG_BACKGROUND="Resources/DMG/background.png"
PYTHON_TOOLS_DIR="$BUILD_DIR/python-tools"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p "$RELEASE_DIR"
rm -rf "$STAGING_DIR" "$DMG_PATH" "$DMG_TEMP" "$RELEASE_DIR/$APP_NAME.app"

swift script/generate_brand_assets.swift

if ! PYTHONPATH="$PYTHON_TOOLS_DIR" python3 - <<'PY' >/dev/null 2>&1
import ds_store, mac_alias
PY
then
  python3 -m pip install --target "$PYTHON_TOOLS_DIR" ds_store mac_alias biplist
fi

xcodebuild \
  -project "$PROJECT_NAME" \
  -scheme "$SCHEME" \
  -destination "platform=macOS,arch=arm64" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR" \
  build

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

mkdir -p "$STAGING_DIR"
ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$STAGING_DIR/.background"
cp "$DMG_BACKGROUND" "$STAGING_DIR/.background/background.png"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDRW \
  "$DMG_TEMP"

MOUNT_INFO="$(hdiutil attach "$DMG_TEMP" -readwrite -noverify -noautoopen)"
MOUNT_POINT="$(printf '%s\n' "$MOUNT_INFO" | grep -o '/Volumes/.*' | tail -n 1)"

if [[ -z "$MOUNT_POINT" ]]; then
  echo "Could not mount temporary DMG" >&2
  exit 1
fi

cleanup_mount() {
  hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
}
trap cleanup_mount EXIT

if PYTHONPATH="$PYTHON_TOOLS_DIR" python3 script/write_dmg_ds_store.py "$MOUNT_POINT"; then
  SetFile -a V "$MOUNT_POINT/.background" "$MOUNT_POINT/.DS_Store" || true
  echo "Applied DMG layout metadata"
elif osascript <<OSA
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {100, 100, 740, 500}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "$APP_NAME.app" of container window to {185, 205}
    set position of item "Applications" of container window to {455, 205}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
OSA
then
  echo "Applied Finder DMG layout"
else
  echo "Warning: Finder DMG layout was skipped. Grant Automation access to the shell/Codex app to enable custom icon positions." >&2
fi

sync
hdiutil detach "$MOUNT_POINT"
trap - EXIT

hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$DMG_TEMP"

hdiutil verify "$DMG_PATH"
ditto "$APP_BUNDLE" "$RELEASE_DIR/$APP_NAME.app"

echo "$DMG_PATH"

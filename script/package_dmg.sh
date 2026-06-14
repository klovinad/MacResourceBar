#!/usr/bin/env bash
set -euo pipefail

APP_NAME="NetworkMenuMonitor"
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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p "$RELEASE_DIR"
rm -rf "$STAGING_DIR" "$DMG_PATH" "$RELEASE_DIR/$APP_NAME.app"

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

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

hdiutil verify "$DMG_PATH"
ditto "$APP_BUNDLE" "$RELEASE_DIR/$APP_NAME.app"

echo "$DMG_PATH"

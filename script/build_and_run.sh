#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="NetworkMenuMonitor"
PROJECT_NAME="NetworkMenuMonitor.xcodeproj"
SCHEME="NetworkMenuMonitor"
CONFIGURATION="Debug"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
BUNDLE_ID="com.networkmenumonitor.app"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -f "/usr/bin/nettop -P -L 0 -d -x -n -s" >/dev/null 2>&1 || true

xcodebuild \
  -project "$PROJECT_NAME" \
  -scheme "$SCHEME" \
  -destination "platform=macOS,arch=arm64" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MacResourceBar"
PROJECT_NAME="NetworkMenuMonitor.xcodeproj"
SCHEME="NetworkMenuMonitor"
CONFIGURATION="Debug"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
BUNDLE_ID="com.klovinad.MacResourceBar"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

terminate_process() {
  local process_name="$1"

  pkill -x "$process_name" >/dev/null 2>&1 || true
  for _ in {1..40}; do
    if ! pgrep -x "$process_name" >/dev/null 2>&1; then
      return
    fi
    sleep 0.1
  done

  pkill -9 -x "$process_name" >/dev/null 2>&1 || true
}

terminate_process "$APP_NAME"
terminate_process "NetworkMenuMonitor"
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

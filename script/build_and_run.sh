#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--build-only|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *) echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
BUILD_DIR="${BUILD_DIR:-build}"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/MacResourceBar.app"

# A failed build must leave the running monitor untouched.
xcodebuild \
  -project NetworkMenuMonitor.xcodeproj \
  -scheme NetworkMenuMonitor \
  -destination "platform=macOS,arch=$(uname -m)" \
  -configuration Debug \
  -derivedDataPath "$BUILD_DIR" \
  build

[[ "$MODE" != "--build-only" ]] || exit 0

if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then
  swift script/launch_app.swift "$APP_BUNDLE" --stop-only
  exec lldb -- "$APP_BUNDLE/Contents/MacOS/MacResourceBar"
fi

swift script/launch_app.swift "$APP_BUNDLE" --show-popover
case "$MODE" in
  --logs|logs)
    exec /usr/bin/log stream --info --style compact --predicate 'process == "MacResourceBar"'
    ;;
  --telemetry|telemetry)
    exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.klovinad.MacResourceBar"'
    ;;
esac

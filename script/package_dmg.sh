#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MacResourceBar"
PROJECT_NAME="NetworkMenuMonitor.xcodeproj"
SCHEME="NetworkMenuMonitor"
CONFIGURATION="Release"
BUILD_DIR="${BUILD_DIR:-build-release}"
RELEASE_DIR="${RELEASE_DIR:-Release}"
RELEASE_MODE="${RELEASE_MODE:-local}"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
APP_BUNDLE="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
DMG_BACKGROUND="Resources/DMG/background.png"
PYTHON_TOOLS_DIR="$BUILD_DIR/python-tools"
CHECKSUM_PATH=""

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

case "$RELEASE_MODE" in
  local | public) ;;
  *)
    echo "RELEASE_MODE must be 'local' or 'public'" >&2
    exit 2
    ;;
esac

BUILD_SETTINGS="$({
  xcodebuild \
    -project "$PROJECT_NAME" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -showBuildSettings
})"
VERSION="$(printf '%s\n' "$BUILD_SETTINGS" | awk '/^[[:space:]]*MARKETING_VERSION = / { value = $3 } END { print value }')"
BUILD_NUMBER="$(printf '%s\n' "$BUILD_SETTINGS" | awk '/^[[:space:]]*CURRENT_PROJECT_VERSION = / { value = $3 } END { print value }')"

if [[ -z "$VERSION" || -z "$BUILD_NUMBER" ]]; then
  echo "Could not read version metadata from Xcode build settings" >&2
  exit 1
fi

if [[ "$RELEASE_MODE" == "local" ]]; then
  DMG_NAME="$APP_NAME-$VERSION-local.dmg"
else
  DMG_NAME="$APP_NAME-$VERSION.dmg"
fi
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"

NOTARY_ARGS=()
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARYTOOL_PROFILE")
elif [[ -n "${APP_STORE_CONNECT_KEY_FILE:-}" && -n "${APP_STORE_CONNECT_KEY_ID:-}" && -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  NOTARY_ARGS=(
    --key "$APP_STORE_CONNECT_KEY_FILE"
    --key-id "$APP_STORE_CONNECT_KEY_ID"
    --issuer "$APP_STORE_CONNECT_ISSUER_ID"
  )
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  NOTARY_ARGS=(
    --apple-id "$APPLE_ID"
    --team-id "$APPLE_TEAM_ID"
    --password "$APPLE_APP_SPECIFIC_PASSWORD"
  )
fi

if [[ "$RELEASE_MODE" == "public" && ( -z "$DEVELOPER_ID_APPLICATION" || "$DEVELOPER_ID_APPLICATION" == "-" ) ]]; then
  echo "Public packaging requires DEVELOPER_ID_APPLICATION; ad-hoc signing is local-only" >&2
  exit 2
fi

if [[ "$RELEASE_MODE" == "public" && ${#NOTARY_ARGS[@]} -eq 0 ]]; then
  echo "Public packaging requires notarization credentials; see RELEASE.md" >&2
  exit 2
fi

# All scratch content belongs to this invocation. Failed builds/signing leave
# the previous release intact.
if [[ "$RELEASE_MODE" == "public" ]]; then
  if [[ "$DEVELOPER_ID_APPLICATION" != "Developer ID Application:"* ]]; then
    echo "Public packaging requires a Developer ID Application identity" >&2
    exit 2
  fi
fi

mkdir -p "$RELEASE_DIR" "$BUILD_DIR"
WORK_DIR="$(mktemp -d "$BUILD_DIR/package.XXXXXX")"
STAGING_DIR="$WORK_DIR/staging"
DMG_TEMP="$WORK_DIR/temporary.dmg"
NOTARY_ZIP="$WORK_DIR/notary.zip"
DMG_CANDIDATE="$WORK_DIR/$DMG_NAME"
MOUNT_POINT=""
cleanup() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || {
      echo "Temporary image still mounted at $MOUNT_POINT; preserved $WORK_DIR" >&2
      return
    }
  fi
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

# Local mode is offline packaging, even if signing variables exist in the shell.
if [[ "$RELEASE_MODE" == "local" ]]; then
  DEVELOPER_ID_APPLICATION=""
  NOTARY_ARGS=()
fi

if [[ ! -f "$DMG_BACKGROUND" ]]; then
  echo "Missing DMG background: $DMG_BACKGROUND" >&2
  exit 1
fi

if ! PYTHONPATH="$PYTHON_TOOLS_DIR" python3 - <<'PY' >/dev/null 2>&1
import ds_store, mac_alias
PY
then
  python3 -m pip install \
    --target "$PYTHON_TOOLS_DIR" \
    ds_store==1.3.2 \
    mac_alias==2.2.3 \
    biplist==1.0.3
fi

echo "Building universal $APP_NAME $VERSION ($CONFIGURATION)"
xcodebuild \
  -project "$PROJECT_NAME" \
  -scheme "$SCHEME" \
  -destination "generic/platform=macOS" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

EXECUTABLE_PATH="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ARCHITECTURES="$(lipo -archs "$EXECUTABLE_PATH")"
if [[ "$ARCHITECTURES" != *arm64* || "$ARCHITECTURES" != *x86_64* ]]; then
  echo "Universal build verification failed: found '$ARCHITECTURES'" >&2
  exit 1
fi

ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
ACTUAL_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
if [[ "$ACTUAL_VERSION" != "$VERSION" || "$ACTUAL_BUILD_NUMBER" != "$BUILD_NUMBER" ]]; then
  echo "Bundle version mismatch: expected $VERSION ($BUILD_NUMBER), found $ACTUAL_VERSION ($ACTUAL_BUILD_NUMBER)" >&2
  exit 1
fi

if [[ -n "$DEVELOPER_ID_APPLICATION" ]]; then
  echo "Signing app with Developer ID"
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$APP_BUNDLE"
else
  echo "Local development package: applying ad-hoc signature"
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if [[ "$RELEASE_MODE" == "public" ]]; then
  SIGNING_INFO="$(codesign -d --verbose=4 "$APP_BUNDLE" 2>&1)"
  if [[ "$SIGNING_INFO" != *"Authority=Developer ID Application:"* ]]; then
    echo "Public package is not signed by a Developer ID Application certificate" >&2
    exit 1
  fi
fi

if [[ -n "$DEVELOPER_ID_APPLICATION" && ${#NOTARY_ARGS[@]} -gt 0 ]]; then
  echo "Notarizing app bundle"
  ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  rm -f "$NOTARY_ZIP"
fi

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

hdiutil attach "$DMG_TEMP" -readwrite -noverify -noautoopen -plist > "$WORK_DIR/mount.plist"
MOUNT_POINT="$(python3 - "$WORK_DIR/mount.plist" <<'MOUNT_PY'
import plistlib, sys
with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)
mounts = [entry["mount-point"] for entry in info["system-entities"] if "mount-point" in entry]
if len(mounts) != 1:
    raise SystemExit("Expected exactly one temporary mounted volume")
print(mounts[0])
MOUNT_PY
)"
[[ -n "$MOUNT_POINT" ]] || { echo "Could not mount temporary DMG" >&2; exit 1; }

# Write layout directly: no Finder activation or Automation permission needed.
PYTHONPATH="$PYTHON_TOOLS_DIR" python3 script/write_dmg_ds_store.py "$MOUNT_POINT"
SetFile -a V "$MOUNT_POINT/.background" "$MOUNT_POINT/.DS_Store" || true

/bin/rm -rf -- "$MOUNT_POINT/.fseventsd"
sync
hdiutil detach "$MOUNT_POINT"
MOUNT_POINT=""

hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_CANDIDATE"
rm -f "$DMG_TEMP"

if [[ -n "$DEVELOPER_ID_APPLICATION" ]]; then
  echo "Signing DMG with Developer ID"
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_CANDIDATE"
  codesign --verify --verbose=2 "$DMG_CANDIDATE"
fi

if [[ -n "$DEVELOPER_ID_APPLICATION" && ${#NOTARY_ARGS[@]} -gt 0 ]]; then
  echo "Notarizing DMG"
  xcrun notarytool submit "$DMG_CANDIDATE" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$DMG_CANDIDATE"
  xcrun stapler validate "$DMG_CANDIDATE"
elif [[ -n "$DEVELOPER_ID_APPLICATION" ]]; then
  echo "Warning: package is Developer ID signed but not notarized; configure credentials from RELEASE.md" >&2
fi

hdiutil verify "$DMG_CANDIDATE"
if [[ "$RELEASE_MODE" == "public" ]]; then
  spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
fi
# Copy the exact signed bundle only after every validation above succeeded.
# Keep the previous bundle as a rollback until its replacement is complete.
BUNDLE_CANDIDATE="$RELEASE_DIR/.$APP_NAME-candidate-$$.app"
ditto "$APP_BUNDLE" "$BUNDLE_CANDIDATE"
if [[ -e "$RELEASE_DIR/$APP_NAME.app" ]]; then
  mv "$RELEASE_DIR/$APP_NAME.app" "$WORK_DIR/previous.app"
fi
mv "$BUNDLE_CANDIDATE" "$RELEASE_DIR/$APP_NAME.app"
mv "$DMG_CANDIDATE" "$DMG_PATH"
(
  cd "$(dirname "$DMG_PATH")"
  shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

echo "Created $DMG_PATH"
echo "Checksum: $CHECKSUM_PATH"
echo "Architectures: $ARCHITECTURES"

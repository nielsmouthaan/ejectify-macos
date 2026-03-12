#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  $0 --notary-profile <keychain_profile_name> [--publish-path <absolute_updates_directory> --sparkle-private-key <absolute_private_key_path>]

Options:
  --notary-profile      Required. notarytool keychain profile name.
  --publish-path        Optional. When set, appcast.xml and Sparkle zip are copied here.
  --sparkle-private-key Required when --publish-path is set. Path to Sparkle EdDSA private key file.
  -h, --help            Show this help.
USAGE
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

resolve_project_path() {
  local root_dir="$1"
  local project_path

  project_path="$(find "$root_dir" -maxdepth 1 -type d -name '*.xcodeproj' | head -n 1)"
  if [[ -z "$project_path" ]]; then
    echo "Could not resolve an .xcodeproj in $root_dir" >&2
    exit 1
  fi

  echo "$project_path"
}

resolve_sparkle_tool() {
  local tool_name="$1"

  if command -v "$tool_name" >/dev/null 2>&1; then
    command -v "$tool_name"
    return
  fi

  local resolved_path
  resolved_path="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type f -path "*/SourcePackages/checkouts/Sparkle/bin/$tool_name" -perm -111 2>/dev/null | head -n 1)"

  if [[ -z "$resolved_path" ]]; then
    echo "Could not find Sparkle tool '$tool_name'. Build once with Sparkle or install Sparkle tools." >&2
    exit 1
  fi

  echo "$resolved_path"
}

NOTARY_PROFILE=""
PUBLISH_PATH=""
SPARKLE_PRIVATE_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notary-profile)
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --publish-path)
      PUBLISH_PATH="$2"
      shift 2
      ;;
    --sparkle-private-key)
      SPARKLE_PRIVATE_KEY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "--notary-profile is required." >&2
  usage
  exit 1
fi

if [[ -n "$PUBLISH_PATH" && -z "$SPARKLE_PRIVATE_KEY" ]]; then
  echo "--sparkle-private-key is required when --publish-path is set." >&2
  exit 1
fi

if [[ -n "$SPARKLE_PRIVATE_KEY" && ! -f "$SPARKLE_PRIVATE_KEY" ]]; then
  echo "Sparkle private key file does not exist: $SPARKLE_PRIVATE_KEY" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="$(resolve_project_path "$ROOT_DIR")"
SCHEME="$(basename "$PROJECT_PATH" .xcodeproj)"
CONFIGURATION="Release"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/${SCHEME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"

require_command xcodebuild
require_command create-dmg
require_command codesign
require_command xcrun
require_command ditto
require_command defaults
require_command find

mkdir -p "$BUILD_DIR" "$DIST_DIR"

cat > "$EXPORT_OPTIONS_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
PLIST

echo "Archiving $SCHEME ($CONFIGURATION)..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  archive

echo "Exporting archive for Developer ID distribution..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

APP_PATH="$EXPORT_DIR/$SCHEME.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Resolved app path does not exist: $APP_PATH" >&2
  exit 1
fi

APP_VERSION="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString)"
DOWNLOAD_URL_PREFIX="https://ejectify.app/updates"
SPARKLE_ZIP_PATH="$DIST_DIR/${SCHEME}-${APP_VERSION}.zip"

if [[ -n "$PUBLISH_PATH" ]]; then
  mkdir -p "$PUBLISH_PATH"
fi

echo "Verifying app signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Submitting app for notarization..."
xcrun notarytool submit "$APP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "Stapling app notarization ticket..."
xcrun stapler staple "$APP_PATH"

if command -v spctl >/dev/null 2>&1; then
  echo "Gatekeeper app assessment (informational):"
  spctl -a -vvv -t execute "$APP_PATH" || true
fi

echo "Creating signed DMG (automatic identity detection)..."
create-dmg --overwrite "$APP_PATH" "$DIST_DIR"

echo "Locating generated DMG..."
DMG_PATH="$(find "$DIST_DIR" -maxdepth 1 -type f -name '*.dmg' -print0 | xargs -0 ls -t | head -n 1)"

if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
  echo "No DMG found in $DIST_DIR after packaging." >&2
  exit 1
fi

echo "Verifying DMG signature..."
codesign --verify --strict "$DMG_PATH"

echo "Submitting DMG for notarization..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "Stapling DMG notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo "Validating stapled DMG ticket..."
xcrun stapler validate "$DMG_PATH"

if command -v spctl >/dev/null 2>&1; then
  echo "Gatekeeper DMG assessment (informational):"
  spctl -a -vvv -t open "$DMG_PATH" || true
fi

APPCAST_PATH=""

if [[ -n "$PUBLISH_PATH" ]]; then
  echo "Creating Sparkle update archive..."
  ditto -c -k --keepParent "$APP_PATH" "$SPARKLE_ZIP_PATH"

  GENERATE_APPCAST="$(resolve_sparkle_tool generate_appcast)"
  APPCAST_BUILD_DIR="$BUILD_DIR/sparkle"
  mkdir -p "$APPCAST_BUILD_DIR"

  cp "$SPARKLE_ZIP_PATH" "$APPCAST_BUILD_DIR/"

  echo "Generating appcast.xml..."
  "$GENERATE_APPCAST" \
    --ed-key-file "$SPARKLE_PRIVATE_KEY" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    "$APPCAST_BUILD_DIR"

  APPCAST_PATH="$APPCAST_BUILD_DIR/appcast.xml"

  if [[ ! -f "$APPCAST_PATH" ]]; then
    echo "Sparkle appcast generation failed: appcast.xml not found." >&2
    exit 1
  fi

  cp "$APPCAST_PATH" "$DIST_DIR/appcast.xml"
  cp "$SPARKLE_ZIP_PATH" "$PUBLISH_PATH/"
  cp "$APPCAST_PATH" "$PUBLISH_PATH/appcast.xml"

  echo "Published Sparkle artifacts to: $PUBLISH_PATH"
fi

echo "Done."
echo "Project: $PROJECT_PATH"
echo "Scheme: $SCHEME"
echo "App: $APP_PATH"
echo "DMG: $DMG_PATH"
if [[ -n "$PUBLISH_PATH" ]]; then
  echo "Sparkle ZIP: $SPARKLE_ZIP_PATH"
  echo "Appcast: $APPCAST_PATH"
fi

echo "Cleaning temporary build artifacts..."
rm -rf "$BUILD_DIR"

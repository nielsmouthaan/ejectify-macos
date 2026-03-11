#!/usr/bin/env bash

set -euo pipefail

SCHEME="Ejectify"
PROJECT_PATH="./Ejectify.xcodeproj"
CONFIGURATION="Release"
DIST_DIR="./dist"
BUILD_DIR="./build"
ARCHIVE_PATH="$BUILD_DIR/Ejectify.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
NOTARYTOOL_KEYCHAIN_PROFILE="Default"

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

require_command xcodebuild
require_command create-dmg
require_command codesign
require_command xcrun

mkdir -p "$BUILD_DIR" "$DIST_DIR"

cat > "$EXPORT_OPTIONS_PLIST" <<'EOF'
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
EOF

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

APP_PATH="$EXPORT_DIR/Ejectify.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Resolved app path does not exist: $APP_PATH" >&2
  exit 1
fi

echo "Creating signed DMG (automatic identity detection)..."
create-dmg --overwrite "$APP_PATH" "$DIST_DIR"

echo "Locating generated DMG..."
DMG_PATH="$(find "$DIST_DIR" -maxdepth 1 -type f -name '*.dmg' -print0 | xargs -0 ls -t | head -n 1)"

if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
  echo "No DMG found in $DIST_DIR after packaging." >&2
  exit 1
fi

echo "Verifying app signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Verifying DMG signature..."
codesign --verify --strict "$DMG_PATH"

echo "Submitting DMG for notarization..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" \
  --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo "Validating stapled ticket..."
xcrun stapler validate "$DMG_PATH"

if command -v spctl >/dev/null 2>&1; then
  echo "Gatekeeper assessment (informational):"
  spctl -a -vvv -t open "$DMG_PATH" || true
fi

echo "Done."
echo "App: $APP_PATH"
echo "DMG: $DMG_PATH"

echo "Cleaning temporary build artifacts..."
rm -rf "$BUILD_DIR"

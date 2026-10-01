#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Flux Universal Release Build & Package Script
# Produces:
#   Flux.dmg / Flux-beta.dmg -> Universal macOS 15.0+ / 26+ binary
# ==============================================================================

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/build_artifacts"
CREATE_DMG="/opt/homebrew/bin/create-dmg"

if ! command -v "$CREATE_DMG" &> /dev/null; then
  echo "Error: create-dmg not found at $CREATE_DMG. Please run 'brew install create-dmg'."
  exit 1
fi

# Detect beta vs stable from project.pbxproj
BUNDLE_ID=$(grep -o 'PRODUCT_BUNDLE_IDENTIFIER = [^;]*' "$PROJECT_ROOT/flux.xcodeproj/project.pbxproj" | head -1 | sed 's/PRODUCT_BUNDLE_IDENTIFIER = //;s/;//')
DISPLAY_NAME=$(grep -o 'INFOPLIST_KEY_CFBundleDisplayName = [^;]*' "$PROJECT_ROOT/flux.xcodeproj/project.pbxproj" | head -1 | sed 's/INFOPLIST_KEY_CFBundleDisplayName = //;s/;//;s/"//g')
VERSION=$(grep -o 'MARKETING_VERSION = [^;]*' "$PROJECT_ROOT/flux.xcodeproj/project.pbxproj" | head -1 | sed 's/MARKETING_VERSION = //;s/;//;s/"//g')

if [[ "$BUNDLE_ID" == *"beta"* ]]; then
  IS_BETA=true
  DMG_PREFIX="Flux-beta"
  APP_NAME="Flux (beta)"
  VOL_NAME="Flux (beta)"
else
  IS_BETA=false
  DMG_PREFIX="Flux"
  APP_NAME="Flux"
  VOL_NAME="Flux"
fi

echo "==> Detected: $DISPLAY_NAME ($BUNDLE_ID) v$VERSION"
echo "==> DMG prefix: $DMG_PREFIX"

build_release() {
  echo "==> Building $APP_NAME Universal Release (macOS 15.0+ / 26+)..."
  local SYMROOT="$BUILD_ROOT/release"
  rm -rf "$SYMROOT"
  
  xcodebuild -scheme flux \
    -configuration Release \
    -destination 'platform=macOS' \
    MACOSX_DEPLOYMENT_TARGET=15.0 \
    CODE_SIGN_ALLOWED=YES \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS="" \
    SYMROOT="$SYMROOT" \
    build

  local APP_PATH="$SYMROOT/Release/flux.app"
  local STAGING_DIR="/tmp/flux-dmg-staging"
  local OUTPUT_DMG="$PROJECT_ROOT/${DMG_PREFIX}-${VERSION}.dmg"

  echo "==> Packaging $OUTPUT_DMG..."
  rm -rf "$STAGING_DIR" "$OUTPUT_DMG"
  mkdir -p "$STAGING_DIR"
  cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"

  # Set the correct app name
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$STAGING_DIR/$APP_NAME.app/Contents/Info.plist" || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$STAGING_DIR/$APP_NAME.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$STAGING_DIR/$APP_NAME.app/Contents/Info.plist" || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$STAGING_DIR/$APP_NAME.app/Contents/Info.plist"
  xattr -cr "$STAGING_DIR/$APP_NAME.app"
  codesign --force --deep --options runtime --entitlements "$PROJECT_ROOT/flux/flux.entitlements" --sign - "$STAGING_DIR/$APP_NAME.app"

  "$CREATE_DMG" \
    --volname "$VOL_NAME" \
    --volicon "$STAGING_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 128 \
    --icon "$APP_NAME.app" 140 180 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 400 180 \
    --overwrite \
    "$OUTPUT_DMG" \
    "$STAGING_DIR"

  rm -rf "$STAGING_DIR"
  echo "==> Done: $OUTPUT_DMG"
}

build_release

echo ""
echo "=================================================="
echo "Artifacts Built Successfully:"
for DMG in "$PROJECT_ROOT"/${DMG_PREFIX}-${VERSION}*.dmg; do
  if [ -f "$DMG" ]; then
    echo "  - $(basename "$DMG") ($(du -h "$DMG" | cut -f1))"
    shasum -a 256 "$DMG"
  fi
done
echo "=================================================="
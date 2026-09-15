#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Flux Dual-Release Build & Package Script
# Produces:
#   1. Flux.dmg / Flux-beta.dmg  -> macOS 26.0+ (Native Apple Liquid Glass)
#   2. Flux-macOS15.dmg / Flux-beta-macOS15.dmg  -> macOS 15.0+ (Vibrancy Fallback)
# ==============================================================================

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/build_artifacts"
CREATE_DMG="/opt/homebrew/bin/create-dmg"

if ! command -v "$CREATE_DMG" &> /dev/null; then
  echo "Error: create-dmg not found at $CREATE_DMG. Please run 'brew install create-dmg'."
  exit 1
fi

# Detect beta vs stable from Info.plist
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PROJECT_ROOT/flux/Info.plist" 2>/dev/null || echo "com.entanglon.flux")
DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$PROJECT_ROOT/flux/Info.plist" 2>/dev/null || echo "Flux")
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_ROOT/flux/Info.plist" 2>/dev/null || echo "1.0.0")

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

build_macos26() {
  echo "==> [1/2] Building $APP_NAME (macOS 26+ Liquid Glass Edition)..."
  local SYMROOT="$BUILD_ROOT/macos26"
  rm -rf "$SYMROOT"
  
  xcodebuild -scheme flux \
    -configuration Release \
    -destination 'platform=macOS' \
    MACOSX_DEPLOYMENT_TARGET=26.1 \
    CODE_SIGN_ALLOWED=YES \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS="" \
    SYMROOT="$SYMROOT" \
    build

  local APP_PATH="$SYMROOT/Release/flux.app"
  local STAGING_DIR="/tmp/flux-dmg-staging-26"
  local OUTPUT_DMG="$PROJECT_ROOT/${DMG_PREFIX}-${VERSION}-macOS26+.dmg"

  echo "==> Packaging $OUTPUT_DMG..."
  rm -rf "$STAGING_DIR" "$OUTPUT_DMG"
  mkdir -p "$STAGING_DIR"
  cp -R "$APP_PATH" "$STAGING_DIR/Flux.app"

  # Set the correct app name
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$STAGING_DIR/Flux.app/Contents/Info.plist" || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$STAGING_DIR/Flux.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$STAGING_DIR/Flux.app/Contents/Info.plist" || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$STAGING_DIR/Flux.app/Contents/Info.plist"
  xattr -cr "$STAGING_DIR/Flux.app"
  codesign --force --deep --options runtime --entitlements "$PROJECT_ROOT/flux/flux.entitlements" --sign - "$STAGING_DIR/Flux.app"

  # Also update /Applications/Flux.app for local testing
  echo "==> Updating /Applications/Flux.app..."
  pkill -x "flux" || pkill -x "Flux" || true
  rm -rf /Applications/Flux.app
  cp -R "$STAGING_DIR/Flux.app" /Applications/Flux.app
  xattr -cr /Applications/Flux.app
  codesign --force --deep --options runtime --entitlements "$PROJECT_ROOT/flux/flux.entitlements" --sign - /Applications/Flux.app

  "$CREATE_DMG" \
    --volname "$VOL_NAME" \
    --volicon "$STAGING_DIR/Flux.app/Contents/Resources/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 128 \
    --icon "Flux.app" 140 180 \
    --hide-extension "Flux.app" \
    --app-drop-link 400 180 \
    --overwrite \
    "$OUTPUT_DMG" \
    "$STAGING_DIR"

  rm -rf "$STAGING_DIR"
  echo "==> Done: $OUTPUT_DMG"
}

build_macos15() {
  echo "==> [2/2] Building $APP_NAME Legacy (macOS 15+ Edition)..."
  local SYMROOT="$BUILD_ROOT/macos15"
  rm -rf "$SYMROOT"

  xcodebuild -scheme flux \
    -configuration Release \
    -destination 'platform=macOS' \
    MACOSX_DEPLOYMENT_TARGET=15.0 \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="FLUX_LEGACY" \
    CODE_SIGN_ALLOWED=YES \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS="" \
    SYMROOT="$SYMROOT" \
    build

  local APP_PATH="$SYMROOT/Release/flux.app"
  local STAGING_DIR="/tmp/flux-dmg-staging-15"
  local OUTPUT_DMG="$PROJECT_ROOT/${DMG_PREFIX}-${VERSION}-macOS15+.dmg"

  echo "==> Packaging $OUTPUT_DMG..."
  rm -rf "$STAGING_DIR" "$OUTPUT_DMG"
  mkdir -p "$STAGING_DIR"
  cp -R "$APP_PATH" "$STAGING_DIR/Flux.app"

  # Set the correct app name
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$STAGING_DIR/Flux.app/Contents/Info.plist" || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$STAGING_DIR/Flux.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$STAGING_DIR/Flux.app/Contents/Info.plist" || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$STAGING_DIR/Flux.app/Contents/Info.plist"
  xattr -cr "$STAGING_DIR/Flux.app"
  codesign --force --deep --options runtime --entitlements "$PROJECT_ROOT/flux/flux.entitlements" --sign - "$STAGING_DIR/Flux.app"

  "$CREATE_DMG" \
    --volname "$VOL_NAME" \
    --volicon "$STAGING_DIR/Flux.app/Contents/Resources/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 128 \
    --icon "Flux.app" 140 180 \
    --hide-extension "Flux.app" \
    --app-drop-link 400 180 \
    --overwrite \
    "$OUTPUT_DMG" \
    "$STAGING_DIR"

  rm -rf "$STAGING_DIR"
  echo "==> Done: $OUTPUT_DMG"
}

MODE="${1:---all}"

case "$MODE" in
  --macos26)
    build_macos26
    ;;
  --macos15|--legacy)
    build_macos15
    ;;
  --all)
    build_macos26
    build_macos15
    ;;
  *)
    echo "Usage: $0 [--macos26 | --macos15 | --all]"
    exit 1
    ;;
esac

echo ""
echo "=================================================="
echo "Artifacts Built Successfully:"
for DMG in "$PROJECT_ROOT"/${DMG_PREFIX}-${VERSION}-macOS*.dmg; do
  if [ -f "$DMG" ]; then
    echo "  - $(basename "$DMG") ($(du -h "$DMG" | cut -f1))"
    shasum -a 256 "$DMG"
  fi
done
echo "=================================================="
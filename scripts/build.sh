#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_NAME="Codo"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "=== Building $APP_NAME ==="
cd "$PROJECT_DIR"

# Build release
swift build -c release

echo "=== Assembling $APP_NAME.app ==="

# Clean previous bundle
rm -rf "$APP_BUNDLE"

# Create .app structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"

# Copy app icon (.icns fallback)
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

# Compile Asset Catalog (provides CFBundleIconName for notification banners)
xcrun actool "$PROJECT_DIR/Resources/Assets.xcassets" \
  --compile "$APP_BUNDLE/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist /dev/null \
  >/dev/null

# Copy menubar template images
cp "$PROJECT_DIR/Resources/menubar.png" "$APP_BUNDLE/Contents/Resources/"
cp "$PROJECT_DIR/Resources/menubar@2x.png" "$APP_BUNDLE/Contents/Resources/"

# Sign with Apple Development (stable TCC identity across rebuilds)
SIGN_IDENTITY="Apple Development"
TEAM_ID="93WWLTN9XU"

echo "=== Signing ($SIGN_IDENTITY, team $TEAM_ID) ==="
codesign --force --sign "$SIGN_IDENTITY" \
  --team-id "$TEAM_ID" \
  --options runtime \
  "$APP_BUNDLE"

echo "=== Verifying ==="
codesign -v "$APP_BUNDLE"

echo ""
echo "✓ Built: $APP_BUNDLE"
echo "  Run: open $APP_BUNDLE"

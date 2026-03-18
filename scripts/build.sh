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

# Ad-hoc sign
echo "=== Signing ==="
codesign --force --sign - "$APP_BUNDLE"

echo "=== Verifying ==="
codesign -v "$APP_BUNDLE"

echo ""
echo "✓ Built: $APP_BUNDLE"
echo "  Run: open $APP_BUNDLE"

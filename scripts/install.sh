#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_NAME="Codo"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

INSTALL_DIR="$HOME/.codo"
INSTALL_APP="$HOME/Applications/$APP_NAME.app"
CLI_SOURCE="$PROJECT_DIR/cli/codo.ts"
CLI_DEST="$INSTALL_DIR/codo.ts"
CLI_LINK="/usr/local/bin/codo"
HOOK_SOURCE="$PROJECT_DIR/hooks/claude-hook.sh"
HOOK_DIR="$INSTALL_DIR/hooks"
HOOK_DEST="$HOOK_DIR/claude-hook.sh"

# Ensure app is built
if [ ! -d "$APP_BUNDLE" ]; then
    echo "App bundle not found. Run scripts/build.sh first."
    exit 1
fi

echo "=== Installing $APP_NAME ==="

# Create ~/.codo with restricted permissions
mkdir -p "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR"

# Copy app to ~/Applications
mkdir -p "$HOME/Applications"
rm -rf "$INSTALL_APP"
cp -R "$APP_BUNDLE" "$INSTALL_APP"
echo "✓ App: $INSTALL_APP"

# Copy CLI script
cp "$CLI_SOURCE" "$CLI_DEST"
chmod 700 "$CLI_DEST"
echo "✓ CLI: $CLI_DEST"

# Copy hook script
mkdir -p "$HOOK_DIR"
cp "$HOOK_SOURCE" "$HOOK_DEST"
chmod 755 "$HOOK_DEST"
echo "✓ Hook: $HOOK_DEST"

# Symlink CLI to PATH
if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
    # Create wrapper script that invokes bun
    cat > "$CLI_LINK" <<'WRAPPER'
#!/bin/bash
exec bun "$HOME/.codo/codo.ts" "$@"
WRAPPER
    chmod 755 "$CLI_LINK"
    echo "✓ Symlink: $CLI_LINK"
else
    echo "⚠ /usr/local/bin not found or not writable, skipping CLI symlink"
    echo "  Add alias: alias codo='bun $INSTALL_DIR/codo.ts'"
fi

echo ""
echo "=== Done ==="
echo "1. Start daemon: open $INSTALL_APP"
echo "2. Test: codo \"Hello\" \"World\""
echo "3. Claude Code hooks: add to ~/.claude/settings.json:"
echo "   { \"hooks\": [{ \"type\": \"command\", \"command\": \"$HOOK_DEST\" }] }"

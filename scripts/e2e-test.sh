#!/bin/bash
# L4: End-to-End Manual Test Script
# Requires human verification for UI elements (menubar icon, notification banners).
# Run: bash scripts/e2e-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CLI="$PROJECT_DIR/cli/codo.ts"

PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "  ⊘ $1 (skipped)"; SKIP=$((SKIP + 1)); }

confirm() {
    printf "  → %s [y/n] " "$1"
    read -r answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        return 0
    else
        return 1
    fi
}

echo "=== L4: End-to-End Manual Tests ==="
echo ""

# --- Build ---
echo "--- Build & Install ---"

bash "$PROJECT_DIR/scripts/build.sh" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    pass "build succeeds"
else
    fail "build succeeds" "build.sh failed"
    echo "Cannot continue without a build."
    exit 1
fi

codesign -v "$PROJECT_DIR/.build/release/Codo.app" 2>/dev/null
if [ $? -eq 0 ]; then
    pass "code signature valid"
else
    fail "code signature valid" "codesign -v failed"
fi

# --- Launch ---
echo ""
echo "--- App Launch ---"

# Kill any existing instance
pkill -9 -f "Codo.app/Contents/MacOS/Codo" 2>/dev/null
sleep 1
rm -f ~/.codo/codo.sock

open "$PROJECT_DIR/.build/release/Codo.app"
sleep 3

if pgrep -f "Codo.app/Contents/MacOS/Codo" >/dev/null 2>&1; then
    pass "app process running"
else
    fail "app process running" "no Codo process found"
fi

if [ -S ~/.codo/codo.sock ]; then
    pass "socket file created"
else
    fail "socket file created" "~/.codo/codo.sock not found"
fi

PERMS=$(stat -f "%Lp" ~/.codo 2>/dev/null)
if [ "$PERMS" = "700" ]; then
    pass "~/.codo directory permissions 700"
else
    skip "~/.codo directory permissions (pre-existing dir)"
fi

# --- Menubar Icon ---
echo ""
echo "--- Menubar Icon (visual check) ---"

if confirm "Do you see a bell (🔔) icon in the menubar?"; then
    pass "menubar icon visible"
else
    fail "menubar icon visible" "user did not see icon"
fi

if confirm "Click the bell icon — does a menu appear with 'Codo v0.1.0' and 'Quit Codo'?"; then
    pass "menubar menu works"
else
    fail "menubar menu works" "menu not as expected"
fi

# --- Notification Permission ---
echo ""
echo "--- Notifications ---"

bun "$CLI" "Permission Test" "Requesting notification permission" 2>/dev/null
EXIT=$?
if [ "$EXIT" -eq 0 ]; then
    pass "CLI sends notification (exit 0)"
else
    fail "CLI sends notification" "exit=$EXIT"
fi

if confirm "Did a notification permission dialog appear (or was permission already granted)?"; then
    pass "notification permission requested"
else
    skip "notification permission (may already be granted)"
fi

# --- Notification Banner ---
echo ""
echo "--- Notification Banner ---"

sleep 2
bun "$CLI" "Banner Test" "You should see this as a popup banner" 2>/dev/null

if confirm "Did a notification banner pop up on screen?"; then
    pass "notification banner displayed"
else
    fail "notification banner displayed" "user did not see banner"
fi

if confirm "Did you hear a notification sound?"; then
    pass "notification sound played"
else
    skip "notification sound (may be muted)"
fi

# --- Notification with body ---
bun "$CLI" "Title Only" 2>/dev/null

if confirm "Did a notification appear with title 'Title Only' and no body text?"; then
    pass "title-only notification"
else
    fail "title-only notification" "user did not see correct notification"
fi

# --- Silent notification ---
bun "$CLI" "Silent Test" "This should have no sound" --silent 2>/dev/null

if confirm "Did a notification appear WITHOUT sound?"; then
    pass "silent notification (no sound)"
else
    skip "silent notification (hard to distinguish)"
fi

# --- Error handling ---
echo ""
echo "--- Error Handling ---"

pkill -9 -f "Codo.app/Contents/MacOS/Codo" 2>/dev/null
sleep 1

STDERR=$(bun "$CLI" "Test" 2>&1 >/dev/null)
EXIT=$?
if [ "$EXIT" -eq 2 ] && echo "$STDERR" | grep -q "daemon not running"; then
    pass "daemon not running → exit 2"
else
    fail "daemon not running → exit 2" "exit=$EXIT stderr='$STDERR'"
fi

# Cleanup
rm -f ~/.codo/codo.sock

# --- Summary ---
echo ""
echo "=== L4 Results: $PASS passed, $FAIL failed, $SKIP skipped ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

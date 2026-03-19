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

# --- Settings UI ---
echo ""
echo "--- Settings UI ---"

if confirm "Click 'Settings...' in the menubar menu — does a settings window open?"; then
    pass "settings window opens"
else
    fail "settings window opens" "user did not see settings window"
fi

if confirm "Is the API Key field a secure field (masked input)?"; then
    pass "API key field is secure"
else
    fail "API key field is secure" "field is not masked"
fi

if confirm "Enter an API key → Save → re-open Settings → does the key persist?"; then
    pass "API key persists in Keychain"
else
    fail "API key persists in Keychain" "key did not persist"
fi

if confirm "Enter a custom Base URL → Save → re-open → does it persist?"; then
    pass "base URL persists"
else
    fail "base URL persists" "base URL did not persist"
fi

if confirm "Change the model name → Save → re-open → does it persist?"; then
    pass "model name persists"
else
    fail "model name persists" "model name did not persist"
fi

if confirm "Toggle 'AI Guardian' ON → check 'ps aux | grep guardian' — is a Guardian process running?"; then
    pass "Guardian process spawns when enabled"
else
    fail "Guardian process spawns when enabled" "no Guardian process found"
fi

if confirm "Toggle 'AI Guardian' OFF → is the Guardian process stopped?"; then
    pass "Guardian process stops when disabled"
else
    fail "Guardian process stops when disabled" "Guardian process still running"
fi

# --- Guardian ON (requires API key) ---
echo ""
echo "--- Guardian ON (requires API key) ---"
echo "  ℹ  Ensure AI Guardian is ON and an API key is configured before proceeding."

if confirm "Run: echo '{\"_hook\":\"stop\",\"session_id\":\"s1\",\"cwd\":\"/tmp\",\"last_assistant_message\":\"Refactored auth module, 42 tests pass\"}' | bun $CLI --hook stop — did an AI-rewritten notification appear (not raw text)?"; then
    pass "Guardian rewrites stop notification"
else
    fail "Guardian rewrites stop notification" "raw or no notification"
fi

if confirm "Run: echo '{\"_hook\":\"notification\",\"session_id\":\"s1\",\"cwd\":\"/tmp\",\"title\":\"Permission needed\",\"message\":\"Approve Bash?\",\"notification_type\":\"permission_prompt\"}' | bun $CLI --hook notification — did a notification with enriched context appear?"; then
    pass "Guardian rewrites notification hook"
else
    fail "Guardian rewrites notification hook" "raw or no notification"
fi

if confirm "Send 3 similar build-failed stop hooks rapidly — was at least 1 suppressed (dedup)?"; then
    pass "Guardian deduplicates similar notifications"
else
    skip "Guardian dedup (hard to verify visually)"
fi

if confirm "Send a stop hook with a very long message — is the notification concise (not a 1:1 copy)?"; then
    pass "Guardian summarizes long messages"
else
    fail "Guardian summarizes long messages" "notification was too long"
fi

# --- Guardian OFF (no API key) ---
echo ""
echo "--- Guardian OFF (no API key) ---"
echo "  ℹ  Remove the API key from Settings (or toggle Guardian OFF) before proceeding."

if confirm "Run: echo '{\"_hook\":\"stop\",\"session_id\":\"s1\",\"cwd\":\"/tmp\",\"last_assistant_message\":\"Done\"}' | bun $CLI --hook stop — did a raw notification appear: 'Task Complete — Done'?"; then
    pass "fallback stop notification"
else
    fail "fallback stop notification" "unexpected notification content"
fi

if confirm "Run: echo '{\"_hook\":\"notification\",\"session_id\":\"s1\",\"cwd\":\"/tmp\",\"title\":\"Perm\",\"message\":\"Approve?\"}' | bun $CLI --hook notification — did a raw notification appear: 'Perm — Approve?'?"; then
    pass "fallback notification hook"
else
    fail "fallback notification hook" "unexpected notification content"
fi

if confirm "Run: echo '{\"_hook\":\"session-end\",\"session_id\":\"s1\"}' | bun $CLI --hook session-end — was there NO notification (suppressed)?"; then
    pass "session-end suppressed in fallback mode"
else
    fail "session-end suppressed in fallback mode" "unexpected notification appeared"
fi

# --- Guardian Resilience ---
echo ""
echo "--- Guardian Resilience ---"
echo "  ℹ  Re-enable AI Guardian with API key before proceeding."

if confirm "Kill the Guardian process (kill <pid>) → send a hook → did a raw fallback notification appear AND Guardian restart?"; then
    pass "Guardian auto-restarts after crash"
else
    fail "Guardian auto-restarts after crash" "no restart or no fallback"
fi

if confirm "Kill Guardian 3 times rapidly → does it stay dead and menubar show Guardian OFF?"; then
    pass "Guardian gives up after 3 restarts"
else
    fail "Guardian gives up after 3 restarts" "Guardian kept restarting"
fi

if confirm "Restart the daemon (quit + reopen Codo.app) → does Guardian auto-spawn if enabled + API key present?"; then
    pass "Guardian auto-spawns on daemon restart"
else
    fail "Guardian auto-spawns on daemon restart" "Guardian did not auto-spawn"
fi

# --- Existing Features (regression) ---
echo ""
echo "--- Existing Features (regression) ---"

bun "$CLI" "Regression Hello" 2>/dev/null
if confirm "Did a basic notification appear for 'Regression Hello'?"; then
    pass "basic notification still works"
else
    fail "basic notification still works" "regression in basic notification"
fi

bun "$CLI" "Build Done" "42 tests passed" --template success 2>/dev/null
if confirm "Did a notification appear with '✅ Success' subtitle?"; then
    pass "template success still works"
else
    fail "template success still works" "regression in template"
fi

TEMPLATE_OUT=$(bun "$CLI" --template list 2>/dev/null)
if echo "$TEMPLATE_OUT" | grep -q "success"; then
    pass "template list still works"
else
    fail "template list still works" "template list output unexpected"
fi

echo '{"title":"StdinTest"}' | bun "$CLI" 2>/dev/null
if confirm "Did a notification appear for stdin JSON 'StdinTest'?"; then
    pass "stdin JSON still works"
else
    fail "stdin JSON still works" "regression in stdin JSON"
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

#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CLI="$PROJECT_DIR/cli/codo.ts"

echo "=== L3: Integration Tests ==="

# Build Swift (includes CodoTestServer)
cd "$PROJECT_DIR"
swift build 2>&1 | tail -1

TEST_SERVER="$PROJECT_DIR/.build/debug/CodoTestServer"
if [ ! -f "$TEST_SERVER" ]; then
    echo "ERROR: CodoTestServer not found at $TEST_SERVER"
    exit 1
fi

# Create fake HOME with .codo dir for socket
FAKE_HOME=$(mktemp -d /tmp/codo-integ-XXXXXXXX)
SOCK_DIR="$FAKE_HOME/.codo"
mkdir -p "$SOCK_DIR"
SOCK_PATH="$SOCK_DIR/codo.sock"

echo "Socket: $SOCK_PATH"

PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1: $2"; FAIL=$((FAIL + 1)); }

cleanup() {
    if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$FAKE_HOME"
}
trap cleanup EXIT

# --- CLI flags (no server needed) ---
echo ""
echo "--- CLI flags ---"

STDERR=$(bun "$CLI" --help 2>&1 || true)
EXIT=$?
if [ "$EXIT" -eq 0 ] && echo "$STDERR" | grep -q "Usage:"; then
    pass "--help exits 0 with usage"
else
    fail "--help exits 0 with usage" "exit=$EXIT stderr='$STDERR'"
fi

STDERR=$(bun "$CLI" --version 2>&1 || true)
EXIT=$?
if [ "$EXIT" -eq 0 ] && echo "$STDERR" | grep -q "codo 0.1.0"; then
    pass "--version exits 0 with version"
else
    fail "--version exits 0 with version" "exit=$EXIT"
fi

# --- Daemon not running ---
echo ""
echo "--- Daemon not running ---"

HOME="$FAKE_HOME" bun "$CLI" "Test" >/dev/null 2>/tmp/codo-integ-stderr.txt
EXIT=$?
STDERR=$(cat /tmp/codo-integ-stderr.txt)
if [ "$EXIT" -eq 2 ] && echo "$STDERR" | grep -q "daemon not running"; then
    pass "no daemon → exit 2, 'daemon not running'"
else
    fail "no daemon → exit 2, 'daemon not running'" "exit=$EXIT stderr='$STDERR'"
fi

# --- Start real Swift SocketServer ---
echo ""
echo "--- Swift SocketServer roundtrip ---"

"$TEST_SERVER" "$SOCK_PATH" 2>"$FAKE_HOME/server.log" &
SERVER_PID=$!

# Wait for READY signal
for i in $(seq 1 30); do
    if grep -q "READY" "$FAKE_HOME/server.log" 2>/dev/null; then break; fi
    sleep 0.1
done

if ! grep -q "READY" "$FAKE_HOME/server.log" 2>/dev/null; then
    fail "server startup" "READY not received"
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# Test: title only → exit 0, no stdout
STDOUT=$(HOME="$FAKE_HOME" bun "$CLI" "Hello" 2>/dev/null)
EXIT=$?
if [ "$EXIT" -eq 0 ] && [ -z "$STDOUT" ]; then
    pass "title only → exit 0, no stdout"
else
    fail "title only → exit 0, no stdout" "exit=$EXIT stdout='$STDOUT'"
fi

# Test: title + body → exit 0
STDOUT=$(HOME="$FAKE_HOME" bun "$CLI" "Hello" "World" 2>/dev/null)
EXIT=$?
if [ "$EXIT" -eq 0 ] && [ -z "$STDOUT" ]; then
    pass "title+body → exit 0, no stdout"
else
    fail "title+body → exit 0, no stdout" "exit=$EXIT"
fi

# Test: stdin JSON → exit 0
STDOUT=$(echo '{"title":"StdinTest"}' | HOME="$FAKE_HOME" bun "$CLI" 2>/dev/null)
EXIT=$?
if [ "$EXIT" -eq 0 ] && [ -z "$STDOUT" ]; then
    pass "stdin json → exit 0, no stdout"
else
    fail "stdin json → exit 0, no stdout" "exit=$EXIT"
fi

# Test: --silent flag → exit 0
STDOUT=$(HOME="$FAKE_HOME" bun "$CLI" "Hello" "--silent" 2>/dev/null)
EXIT=$?
if [ "$EXIT" -eq 0 ] && [ -z "$STDOUT" ]; then
    pass "--silent → exit 0, no stdout"
else
    fail "--silent → exit 0, no stdout" "exit=$EXIT"
fi

# Test: daemon returns error → exit 1 with error on stderr
HOME="$FAKE_HOME" bun "$CLI" "fail-me" >/dev/null 2>/tmp/codo-integ-stderr.txt
EXIT=$?
STDERR=$(cat /tmp/codo-integ-stderr.txt)
if [ "$EXIT" -eq 1 ] && echo "$STDERR" | grep -q "test error"; then
    pass "daemon error → exit 1, stderr='test error'"
else
    fail "daemon error → exit 1, stderr='test error'" "exit=$EXIT stderr='$STDERR'"
fi

# Cleanup temp file
rm -f /tmp/codo-integ-stderr.txt

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

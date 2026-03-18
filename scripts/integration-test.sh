#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CLI="$PROJECT_DIR/cli/codo.ts"

# Use a temp directory as fake HOME
FAKE_HOME=$(mktemp -d /tmp/codo-integ-XXXXXXXX)
SOCK_DIR="$FAKE_HOME/.codo"
mkdir -p "$SOCK_DIR"
SOCK_PATH="$SOCK_DIR/codo.sock"

echo "=== L3: Integration Tests ==="
echo "Socket: $SOCK_PATH"

# Build debug binary
cd "$PROJECT_DIR"
swift build 2>&1 | tail -1

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

# --- CLI flags ---
echo ""
echo "--- CLI flags ---"

STDERR=$(bun "$CLI" --help 2>&1 || true)
if echo "$STDERR" | grep -q "Usage:"; then
    pass "--help shows usage"
else
    fail "--help shows usage" "got: $STDERR"
fi

STDERR=$(bun "$CLI" --version 2>&1 || true)
if echo "$STDERR" | grep -q "codo 0.1.0"; then
    pass "--version shows version"
else
    fail "--version shows version" "got: $STDERR"
fi

# --- Daemon not running ---
echo ""
echo "--- Daemon not running ---"

RESULT=$(HOME=/tmp/codo-nonexistent bun "$CLI" "Test" 2>&1 || true)
if echo "$RESULT" | grep -q "daemon not running"; then
    pass "daemon not running → correct error"
else
    fail "daemon not running → correct error" "got: $RESULT"
fi

# --- Server roundtrip ---
echo ""
echo "--- Server roundtrip ---"

# Create mock server in Bun
cat > "$FAKE_HOME/mock-server.ts" <<ENDSCRIPT
const socketPath = "${SOCK_PATH}";

process.on("SIGTERM", () => { process.exit(0); });
process.on("SIGINT", () => { process.exit(0); });

Bun.listen({
  unix: socketPath,
  socket: {
    data(socket, data) {
      const req = JSON.parse(data.toString().trim());
      if (req.title === "fail-me") {
        socket.write('{"ok":false,"error":"test error"}' + "\n");
      } else {
        socket.write('{"ok":true}' + "\n");
      }
      socket.end();
    },
    open() {},
    close() {},
    error() {},
  },
});

process.stderr.write("READY\n");
ENDSCRIPT

# Start mock server
bun "$FAKE_HOME/mock-server.ts" 2>"$FAKE_HOME/server.log" &
SERVER_PID=$!

# Wait for socket to appear
for i in $(seq 1 30); do
    if [ -S "$SOCK_PATH" ]; then break; fi
    sleep 0.1
done

if [ ! -S "$SOCK_PATH" ]; then
    fail "server startup" "socket not created"
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# Test: send title via args → exit 0, no stdout
STDOUT=$(HOME="$FAKE_HOME" bun "$CLI" "Hello" 2>/dev/null || true)
EXIT_CODE=${PIPESTATUS[0]:-$?}
if [ -z "$STDOUT" ]; then
    pass "send title → no stdout"
else
    fail "send title → no stdout" "stdout='$STDOUT'"
fi

# Test: send title + body
STDOUT=$(HOME="$FAKE_HOME" bun "$CLI" "Hello" "World" 2>/dev/null || true)
if [ -z "$STDOUT" ]; then
    pass "send title+body → no stdout"
else
    fail "send title+body → no stdout" "stdout='$STDOUT'"
fi

# Test: send via stdin
STDOUT=$(echo '{"title":"StdinTest"}' | HOME="$FAKE_HOME" bun "$CLI" 2>/dev/null || true)
if [ -z "$STDOUT" ]; then
    pass "stdin json → no stdout"
else
    fail "stdin json → no stdout" "stdout='$STDOUT'"
fi

# Test: --silent flag
STDOUT=$(HOME="$FAKE_HOME" bun "$CLI" "Hello" "--silent" 2>/dev/null || true)
if [ -z "$STDOUT" ]; then
    pass "--silent flag → no stdout"
else
    fail "--silent flag → no stdout" "stdout='$STDOUT'"
fi

# Test: daemon returns error → exit 1
STDERR=$(HOME="$FAKE_HOME" bun "$CLI" "fail-me" 2>&1 >/dev/null || true)
if echo "$STDERR" | grep -q "test error"; then
    pass "daemon error → stderr contains error"
else
    fail "daemon error → stderr contains error" "got: $STDERR"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

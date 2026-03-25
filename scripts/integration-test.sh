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
if [ "$EXIT" -eq 0 ] && echo "$STDERR" | grep -q "codo 0.2.0"; then
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

# --- Client error paths ---
echo ""
echo "--- Client error paths ---"

# Test: invalid stdin JSON → exit 1
echo '{"bad json' | HOME="$FAKE_HOME" bun "$CLI" >/dev/null 2>/tmp/codo-integ-stderr.txt
EXIT=$?
STDERR=$(cat /tmp/codo-integ-stderr.txt)
if [ "$EXIT" -eq 1 ] && echo "$STDERR" | grep -q "invalid json"; then
    pass "invalid stdin json → exit 1, 'invalid json'"
else
    fail "invalid stdin json → exit 1, 'invalid json'" "exit=$EXIT stderr='$STDERR'"
fi

# Test: empty title via args → exit 1
HOME="$FAKE_HOME" bun "$CLI" "" >/dev/null 2>/tmp/codo-integ-stderr.txt
EXIT=$?
STDERR=$(cat /tmp/codo-integ-stderr.txt)
if [ "$EXIT" -eq 1 ] && echo "$STDERR" | grep -q "title is required"; then
    pass "empty title → exit 1, 'title is required'"
else
    fail "empty title → exit 1, 'title is required'" "exit=$EXIT stderr='$STDERR'"
fi

# Test: concurrent CLI calls → all succeed
echo ""
echo "--- Concurrent clients ---"

PIDS=""
for i in 1 2 3; do
    HOME="$FAKE_HOME" bun "$CLI" "Concurrent-$i" 2>/dev/null &
    PIDS="$PIDS $!"
done
for pid in $PIDS; do
    wait "$pid" 2>/dev/null
done
# Verify server is still alive by sending one more
STDOUT=$(HOME="$FAKE_HOME" bun "$CLI" "AfterConcurrent" 2>/dev/null)
EXIT=$?
if [ "$EXIT" -eq 0 ] && [ -z "$STDOUT" ]; then
    pass "concurrent clients → server survives, exit 0"
else
    fail "concurrent clients → server survives, exit 0" "exit=$EXIT"
fi

# Cleanup temp file
rm -f /tmp/codo-integ-stderr.txt

# --- Template system ---
echo ""
echo "--- Template system ---"

MSG_LOG="$SOCK_DIR/messages.log"

# Test: --template list → exit 0, stderr contains template names
HOME="$FAKE_HOME" bun "$CLI" --template list >/dev/null 2>/tmp/codo-integ-stderr.txt
EXIT=$?
STDERR=$(cat /tmp/codo-integ-stderr.txt)
if [ "$EXIT" -eq 0 ] && echo "$STDERR" | grep -q "success" && echo "$STDERR" | grep -q "error"; then
    pass "--template list → exit 0, lists templates"
else
    fail "--template list → exit 0, lists templates" "exit=$EXIT stderr='$STDERR'"
fi

# Test: --template success → exit 0, server receives subtitle
HOME="$FAKE_HOME" bun "$CLI" "TemplateTest" --template success 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q "Success"; then
    pass "--template success → server sees subtitle"
else
    fail "--template success → server sees subtitle" "exit=$EXIT last='$LAST'"
fi

# Test: subtitle + threadId roundtrip via stdin
echo '{"title":"SubThread","subtitle":"MySub","threadId":"t1"}' | HOME="$FAKE_HOME" bun "$CLI" 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q '"subtitle":"MySub"' && echo "$LAST" | grep -q '"threadId":"t1"'; then
    pass "subtitle+threadId roundtrip via stdin"
else
    fail "subtitle+threadId roundtrip via stdin" "exit=$EXIT last='$LAST'"
fi

# Test: --thread flag → server receives threadId
HOME="$FAKE_HOME" bun "$CLI" "ThreadTest" --thread "my-build" 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q '"threadId":"my-build"'; then
    pass "--thread flag → server sees threadId"
else
    fail "--thread flag → server sees threadId" "exit=$EXIT last='$LAST'"
fi

# Test: --silent overrides template sound
HOME="$FAKE_HOME" bun "$CLI" "SilentTemplate" --template success --silent 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q '"sound":"none"' && echo "$LAST" | grep -q "Success"; then
    pass "--silent overrides template sound"
else
    fail "--silent overrides template sound" "exit=$EXIT last='$LAST'"
fi

rm -f /tmp/codo-integ-stderr.txt

# --- Hook events ---
echo ""
echo "--- Hook events ---"

# Test: --hook stop roundtrip → server log shows _hook: "stop"
echo '{"session_id":"s1","cwd":"/tmp","last_assistant_message":"Done"}' \
  | HOME="$FAKE_HOME" bun "$CLI" --hook stop 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q '"_hook":"stop"'; then
    pass "--hook stop roundtrip"
else
    fail "--hook stop roundtrip" "exit=$EXIT last='$LAST'"
fi

# Test: --hook notification roundtrip
echo '{"session_id":"s1","cwd":"/tmp","title":"Perm","message":"Approve?","notification_type":"permission_prompt"}' \
  | HOME="$FAKE_HOME" bun "$CLI" --hook notification 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q '"_hook":"notification"'; then
    pass "--hook notification roundtrip"
else
    fail "--hook notification roundtrip" "exit=$EXIT last='$LAST'"
fi

# Test: --hook post-tool-use roundtrip
echo '{"session_id":"s1","cwd":"/tmp","tool_name":"Bash","command":"npm test"}' \
  | HOME="$FAKE_HOME" bun "$CLI" --hook post-tool-use 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q '"tool_name":"Bash"'; then
    pass "--hook post-tool-use roundtrip"
else
    fail "--hook post-tool-use roundtrip" "exit=$EXIT last='$LAST'"
fi

# Test: hook preserves all fields
echo '{"session_id":"s1","cwd":"/tmp/proj","tool_name":"Bash","command":"npm test","custom_field":42}' \
  | HOME="$FAKE_HOME" bun "$CLI" --hook post-tool-use 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q '"session_id":"s1"' \
   && echo "$LAST" | grep -q '"cwd":"/tmp/proj"' \
   && echo "$LAST" | grep -q '"custom_field":42'; then
    pass "hook preserves all fields"
else
    fail "hook preserves all fields" "exit=$EXIT last='$LAST'"
fi

# Test: existing CodoMessage still works after test server update
STDOUT=$(HOME="$FAKE_HOME" bun "$CLI" "AfterHook" 2>/dev/null)
EXIT=$?
if [ "$EXIT" -eq 0 ] && [ -z "$STDOUT" ]; then
    pass "existing CodoMessage unaffected"
else
    fail "existing CodoMessage unaffected" "exit=$EXIT stdout='$STDOUT'"
fi

rm -f /tmp/codo-integ-stderr.txt

# --- Hook script ---
echo ""
echo "--- Hook script ---"

HOOK_SCRIPT="$PROJECT_DIR/hooks/claude-hook.sh"

# Test: script is executable
if [ -x "$HOOK_SCRIPT" ]; then
    pass "hook script is executable"
else
    fail "hook script is executable" "not executable: $HOOK_SCRIPT"
fi

# Test: Stop → _hook:"stop" roundtrip
echo '{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"Done"}' \
  | HOME="$FAKE_HOME" bash "$HOOK_SCRIPT" 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q '"_hook":"stop"'; then
    pass "Stop → _hook:stop roundtrip"
else
    fail "Stop → _hook:stop roundtrip" "exit=$EXIT last='$LAST'"
fi

# Test: SubagentStop → _hook:"subagent-stop" (separate from Stop)
echo '{"hook_event_name":"SubagentStop","session_id":"s1","last_assistant_message":"Sub done"}' \
  | HOME="$FAKE_HOME" bash "$HOOK_SCRIPT" 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q '"_hook":"subagent-stop"'; then
    pass "SubagentStop → _hook:subagent-stop roundtrip"
else
    fail "SubagentStop → _hook:subagent-stop roundtrip" "exit=$EXIT last='$LAST'"
fi

# Test: Notification → _hook:"notification"
echo '{"hook_event_name":"Notification","session_id":"s1","title":"Perm","message":"Approve?"}' \
  | HOME="$FAKE_HOME" bash "$HOOK_SCRIPT" 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q '"_hook":"notification"'; then
    pass "Notification → _hook:notification roundtrip"
else
    fail "Notification → _hook:notification roundtrip" "exit=$EXIT last='$LAST'"
fi

# Test: PostToolUse → _hook:"post-tool-use"
echo '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash","command":"npm test"}' \
  | HOME="$FAKE_HOME" bash "$HOOK_SCRIPT" 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q '"_hook":"post-tool-use"'; then
    pass "PostToolUse → _hook:post-tool-use roundtrip"
else
    fail "PostToolUse → _hook:post-tool-use roundtrip" "exit=$EXIT last='$LAST'"
fi

# Test: PostToolUseFailure → _hook:"post-tool-use-failure"
echo '{"hook_event_name":"PostToolUseFailure","session_id":"s1","tool_name":"Bash","error":"exit 1"}' \
  | HOME="$FAKE_HOME" bash "$HOOK_SCRIPT" 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q '"_hook":"post-tool-use-failure"'; then
    pass "PostToolUseFailure → _hook:post-tool-use-failure roundtrip"
else
    fail "PostToolUseFailure → _hook:post-tool-use-failure roundtrip" "exit=$EXIT last='$LAST'"
fi

# Test: SessionStart + SessionEnd roundtrip
echo '{"hook_event_name":"SessionStart","session_id":"s1"}' \
  | HOME="$FAKE_HOME" bash "$HOOK_SCRIPT" 2>/dev/null
EXIT1=$?
LAST1=$(tail -1 "$MSG_LOG" 2>/dev/null)
echo '{"hook_event_name":"SessionEnd","session_id":"s1"}' \
  | HOME="$FAKE_HOME" bash "$HOOK_SCRIPT" 2>/dev/null
EXIT2=$?
LAST2=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT1" -eq 0 ] && [ "$EXIT2" -eq 0 ] \
   && echo "$LAST1" | grep -q '"_hook":"session-start"' \
   && echo "$LAST2" | grep -q '"_hook":"session-end"'; then
    pass "SessionStart/End roundtrip"
else
    fail "SessionStart/End roundtrip" "exit1=$EXIT1 exit2=$EXIT2 last1='$LAST1' last2='$LAST2'"
fi

# Test: unknown event → exit 0, no dispatch
BEFORE=$(wc -l < "$MSG_LOG" 2>/dev/null || echo 0)
echo '{"hook_event_name":"PreToolUse","session_id":"s1"}' \
  | HOME="$FAKE_HOME" bash "$HOOK_SCRIPT" 2>/dev/null
EXIT=$?
AFTER=$(wc -l < "$MSG_LOG" 2>/dev/null || echo 0)
if [ "$EXIT" -eq 0 ] && [ "$BEFORE" -eq "$AFTER" ]; then
    pass "unknown event → exit 0, no dispatch"
else
    fail "unknown event → exit 0, no dispatch" "exit=$EXIT before=$BEFORE after=$AFTER"
fi

# Test: missing hook_event_name → exit 0
BEFORE=$(wc -l < "$MSG_LOG" 2>/dev/null || echo 0)
echo '{"session_id":"s1"}' \
  | HOME="$FAKE_HOME" bash "$HOOK_SCRIPT" 2>/dev/null
EXIT=$?
AFTER=$(wc -l < "$MSG_LOG" 2>/dev/null || echo 0)
if [ "$EXIT" -eq 0 ] && [ "$BEFORE" -eq "$AFTER" ]; then
    pass "missing event name → exit 0, no dispatch"
else
    fail "missing event name → exit 0, no dispatch" "exit=$EXIT"
fi

# Test: empty stdin → exit 0
BEFORE=$(wc -l < "$MSG_LOG" 2>/dev/null || echo 0)
echo -n "" \
  | HOME="$FAKE_HOME" bash "$HOOK_SCRIPT" 2>/dev/null
EXIT=$?
AFTER=$(wc -l < "$MSG_LOG" 2>/dev/null || echo 0)
if [ "$EXIT" -eq 0 ] && [ "$BEFORE" -eq "$AFTER" ]; then
    pass "empty stdin → exit 0, no dispatch"
else
    fail "empty stdin → exit 0, no dispatch" "exit=$EXIT"
fi

# Test: daemon not running → exit 0 (graceful degradation)
DEAD_HOME=$(mktemp -d /tmp/codo-dead-XXXXXXXX)
mkdir -p "$DEAD_HOME/.codo"
echo '{"hook_event_name":"Stop","session_id":"s1"}' \
  | HOME="$DEAD_HOME" bash "$HOOK_SCRIPT" 2>/dev/null
EXIT=$?
rm -rf "$DEAD_HOME"
if [ "$EXIT" -eq 0 ]; then
    pass "daemon not running → exit 0"
else
    fail "daemon not running → exit 0" "exit=$EXIT"
fi

# Test: CODO_DEBUG_HOOKS=1 → stderr has output
STDERR=$(echo '{"hook_event_name":"Stop","session_id":"s1"}' \
  | HOME="$FAKE_HOME" CODO_DEBUG_HOOKS=1 bash "$HOOK_SCRIPT" 2>&1 >/dev/null)
if echo "$STDERR" | grep -q "\[codo-hook\]"; then
    pass "CODO_DEBUG_HOOKS=1 → stderr has debug output"
else
    fail "CODO_DEBUG_HOOKS=1 → stderr has debug output" "stderr='$STDERR'"
fi

# Test: pretty-printed JSON with spaces around colon
echo '{"hook_event_name": "Stop", "session_id": "s1", "last_assistant_message": "Done"}' \
  | HOME="$FAKE_HOME" bash "$HOOK_SCRIPT" 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q '"_hook":"stop"'; then
    pass "pretty-printed JSON → _hook:stop roundtrip"
else
    fail "pretty-printed JSON → _hook:stop roundtrip" "exit=$EXIT last='$LAST'"
fi

# Test: multiline JSON with spaces around colon
printf '{\n  "hook_event_name": "Notification",\n  "session_id": "s1",\n  "title": "Perm"\n}' \
  | HOME="$FAKE_HOME" bash "$HOOK_SCRIPT" 2>/dev/null
EXIT=$?
LAST=$(tail -1 "$MSG_LOG" 2>/dev/null)
if [ "$EXIT" -eq 0 ] && echo "$LAST" | grep -q '"_hook":"notification"'; then
    pass "multiline JSON → _hook:notification roundtrip"
else
    fail "multiline JSON → _hook:notification roundtrip" "exit=$EXIT last='$LAST'"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

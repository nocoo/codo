#!/bin/bash
# claude-hook.sh — Single entry point for all Claude Code hook events.
#
# Claude Code sends hook JSON on stdin with a "hook_event_name" field.
# This script extracts the event type, maps it to a codo --hook type,
# and forwards the full JSON payload to the codo CLI.
#
# Resilience contract:
#   - NEVER blocks the agent (no set -e, all paths exit 0)
#   - Silent when daemon is down or codo CLI not found
#   - Debug output goes to stderr only (Claude Code ignores stderr)
#
# Usage in ~/.claude/settings.json:
#   { "hooks": [{ "type": "command", "command": "/path/to/claude-hook.sh" }] }
#
# Environment:
#   CODO_DEBUG_HOOKS=1  Enable debug logging to stderr

set +e

DEBUG="${CODO_DEBUG_HOOKS:-0}"

debug() {
  if [ "$DEBUG" = "1" ]; then
    echo "[codo-hook] $*" >&2
  fi
}

# --- Read stdin ---
INPUT=$(cat)

if [ -z "$INPUT" ]; then
  debug "empty stdin, skipping"
  exit 0
fi

# --- Extract hook_event_name (no jq dependency) ---
# Tolerates optional whitespace around colon (compact, pretty-printed, or multiline JSON)
EVENT_NAME=$(echo "$INPUT" | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -oE '"[^"]*"$' | tr -d '"')

if [ -z "$EVENT_NAME" ]; then
  debug "no hook_event_name found, skipping"
  exit 0
fi

debug "event: $EVENT_NAME"

# --- Map Claude Code event → codo hook type ---
case "$EVENT_NAME" in
  Stop|SubagentStop)
    HOOK_TYPE="stop"
    ;;
  Notification)
    HOOK_TYPE="notification"
    ;;
  PostToolUse)
    HOOK_TYPE="post-tool-use"
    ;;
  PostToolUseFailure)
    HOOK_TYPE="post-tool-use-failure"
    ;;
  SessionStart)
    HOOK_TYPE="session-start"
    ;;
  SessionEnd)
    HOOK_TYPE="session-end"
    ;;
  *)
    debug "unhandled event: $EVENT_NAME, skipping"
    exit 0
    ;;
esac

debug "mapped to hook type: $HOOK_TYPE"

# --- Resolve codo CLI path (three-level fallback) ---
CODO_BIN=""

# 1. Already on PATH
if command -v codo >/dev/null 2>&1; then
  CODO_BIN="codo"
# 2. Installed copy at ~/.codo/codo.ts
elif [ -f "$HOME/.codo/codo.ts" ]; then
  CODO_BIN="bun $HOME/.codo/codo.ts"
# 3. Dev mode: relative to this script
else
  SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  DEV_CLI="$SCRIPT_DIR/../cli/codo.ts"
  if [ -f "$DEV_CLI" ]; then
    CODO_BIN="bun $DEV_CLI"
  fi
fi

if [ -z "$CODO_BIN" ]; then
  debug "codo CLI not found, skipping"
  exit 0
fi

debug "using codo: $CODO_BIN"

# --- Forward to codo CLI ---
echo "$INPUT" | $CODO_BIN --hook "$HOOK_TYPE" >/dev/null 2>&1

debug "forwarded, exit code: $?"

exit 0

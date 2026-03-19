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
#
# Logs:
#   ~/.codo/hooks.log — persistent log (INFO+), auto-rotated at 5MB

set +e

DEBUG="${CODO_DEBUG_HOOKS:-0}"
HOOKS_LOG="$HOME/.codo/hooks.log"

# --- Logging ---

hooklog() {
  local level="$1"; shift
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local line="$ts [$level] [hook] $*"
  # Always write to persistent log (INFO and above)
  case "$level" in
    INFO|WARN|ERROR)
      # Simple log rotation: if hooks.log > 5MB, rotate
      if [ -f "$HOOKS_LOG" ]; then
        local size
        size=$(stat -f%z "$HOOKS_LOG" 2>/dev/null || stat -c%s "$HOOKS_LOG" 2>/dev/null || echo 0)
        if [ "$size" -gt 5242880 ] 2>/dev/null; then
          mv -f "$HOOKS_LOG" "${HOOKS_LOG}.1"
        fi
      fi
      echo "$line" >> "$HOOKS_LOG" 2>/dev/null
      ;;
  esac
  # DEBUG also writes to persistent log when CODO_DEBUG_HOOKS=1
  if [ "$DEBUG" = "1" ] && [ "$level" = "DEBUG" ]; then
    echo "$line" >> "$HOOKS_LOG" 2>/dev/null
  fi
  # stderr output for Claude Code debug (only when debug enabled)
  if [ "$DEBUG" = "1" ]; then
    echo "[codo-hook] $*" >&2
  fi
}

# --- Read stdin ---
INPUT=$(cat)

if [ -z "$INPUT" ]; then
  hooklog DEBUG "empty stdin, skipping"
  exit 0
fi

hooklog DEBUG "received event, payload_bytes=${#INPUT}"

# --- Extract hook_event_name (no jq dependency) ---
# Tolerates optional whitespace around colon (compact, pretty-printed, or multiline JSON)
EVENT_NAME=$(echo "$INPUT" | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -oE '"[^"]*"$' | tr -d '"')

if [ -z "$EVENT_NAME" ]; then
  hooklog WARN "no hook_event_name found, skipping"
  exit 0
fi

hooklog DEBUG "event=$EVENT_NAME"

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
    hooklog WARN "unhandled event=$EVENT_NAME, skipping"
    exit 0
    ;;
esac

hooklog INFO "event=$EVENT_NAME mapped=$HOOK_TYPE"

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
  hooklog ERROR "codo CLI not found, skipping"
  exit 0
fi

hooklog DEBUG "bin=$CODO_BIN"

# --- Forward to codo CLI ---
# Capture codo CLI exit code correctly (stderr goes to hooks.log, not /dev/null)
echo "$INPUT" | $CODO_BIN --hook "$HOOK_TYPE" >/dev/null 2>>"$HOOKS_LOG"
CODO_EXIT=${PIPESTATUS[1]:-$?}

if [ "$CODO_EXIT" -eq 0 ]; then
  hooklog INFO "sent hook=$HOOK_TYPE exit=0"
else
  hooklog ERROR "send failed hook=$HOOK_TYPE exit=$CODO_EXIT"
fi

exit 0

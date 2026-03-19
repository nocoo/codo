# Claude Code Hook Integration

Codo supports forwarding Claude Code hook events to the daemon (Guardian AI rewrite or fallback notification). Instead of manually wiring `cat | bun /path/to/codo.ts --hook stop` in `settings.json`, the hook script provides a single entry point that handles event routing automatically.

## Architecture

```
Claude Code agent
  │
  ├─ Stop / SubagentStop / Notification / PostToolUse / ...
  │
  ▼
~/.codo/hooks/claude-hook.sh     ← single entry, all events
  │
  ├─ stdin: JSON with hook_event_name
  ├─ grep → extract event type
  ├─ case → map to codo --hook type
  │
  ▼
codo CLI --hook <type>           ← existing CLI hook path
  │
  ▼
UDS → Codo.app → Guardian / Fallback → macOS notification
```

## Event Mapping

| Claude Code `hook_event_name` | Codo `--hook` type | Notes |
|---|---|---|
| `Stop` | `stop` | Agent turn completed |
| `SubagentStop` | `stop` | Subagent completed, merged into stop |
| `Notification` | `notification` | Permission prompts, etc. |
| `PostToolUse` | `post-tool-use` | Tool call succeeded (Bash matcher only) |
| `PostToolUseFailure` | `post-tool-use-failure` | Tool call failed |
| `SessionStart` | `session-start` | Session started |
| `SessionEnd` | `session-end` | Session ended |
| Others (`UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PreCompact`) | *(skip)* | `exit 0` silently |

## Installation

After running `scripts/install.sh`, the hook script is installed at `~/.codo/hooks/claude-hook.sh`.

```bash
# Build and install
./scripts/build.sh
./scripts/install.sh
```

## Configuration

### Codo Only

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.codo/hooks/claude-hook.sh" }] }
    ],
    "SubagentStop": [
      { "hooks": [{ "type": "command", "command": "~/.codo/hooks/claude-hook.sh" }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "~/.codo/hooks/claude-hook.sh" }] }
    ],
    "PostToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.codo/hooks/claude-hook.sh" }] }
    ],
    "PostToolUseFailure": [
      { "hooks": [{ "type": "command", "command": "~/.codo/hooks/claude-hook.sh" }] }
    ],
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "~/.codo/hooks/claude-hook.sh" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "~/.codo/hooks/claude-hook.sh" }] }
    ]
  }
}
```

### Coexisting with Superset

When running alongside Superset's `notify.sh`, both hook scripts can share event slots:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.superset/hooks/notify.sh" }] },
      { "hooks": [{ "type": "command", "command": "~/.codo/hooks/claude-hook.sh" }] }
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "~/.superset/hooks/notify.sh" }] },
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.codo/hooks/claude-hook.sh" }] }
    ],
    "PostToolUseFailure": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "~/.superset/hooks/notify.sh" }] },
      { "hooks": [{ "type": "command", "command": "~/.codo/hooks/claude-hook.sh" }] }
    ]
  }
}
```

## CLI Path Resolution

The hook script resolves the codo CLI using a three-level fallback:

| Priority | Path | When |
|----------|------|------|
| 1 | `command -v codo` | Installed to PATH (`/usr/local/bin/codo` wrapper) |
| 2 | `$HOME/.codo/codo.ts` | `install.sh` deployed copy |
| 3 | `$(dirname $0)/../cli/codo.ts` | Development mode, relative to script |

All three missing → `exit 0` silently.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CODO_DEBUG_HOOKS` | `0` | Set to `1` for debug logging to stderr |

Debug output goes to stderr only — Claude Code ignores stderr so it never interferes with the agent.

```bash
# Debug a specific event
echo '{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"Done"}' \
  | CODO_DEBUG_HOOKS=1 bash ~/.codo/hooks/claude-hook.sh
```

## Resilience Design

The hook script is designed to **never block or crash the agent**:

- **`set +e`** — no `errexit`, the script handles all errors manually
- **All paths `exit 0`** — even when daemon is down, CLI is missing, or input is malformed
- **No external dependencies** — pure bash + grep, no jq/python/node required
- **No built-in timeout** — trusts the codo CLI's internal `TIMEOUT_MS = 5000`
- **stdout/stderr suppressed** — codo CLI output redirected to `/dev/null`
- **Daemon down = silent skip** — if the socket doesn't exist, codo CLI exits 2 but the hook script still exits 0

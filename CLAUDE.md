# Codo — macOS Notification Guardian

## Architecture

```
Claude Code hooks → claude-hook.sh → codo CLI → Unix socket → Codo.app (daemon)
                                                                  ├─ Guardian alive → stdin pipe → guardian/main.ts (AI)
                                                                  └─ Guardian dead  → FallbackNotification
```

- **Codo.app**: Swift menubar app (NSApplication.accessory, LSUIElement). No Dock icon.
- **Guardian**: Bun subprocess (`guardian/main.ts`), communicates via stdin/stdout JSON lines, stderr → `~/.codo/guardian.log`
- **CLI**: `cli/codo.ts` — sends JSON to daemon via Unix Domain Socket (`~/.codo/codo.sock`)
- **Hook**: `hooks/claude-hook.sh` — maps Claude Code events to `codo --hook <type>`

## Build

```bash
./scripts/build.sh
# Output: .build/release/Codo.app (signed bundle)
```

Manual equivalent:
```bash
swift build -c release
# Then assemble .app bundle, actool, codesign (see scripts/build.sh)
```

## Install (deploy to ~/.codo)

```bash
./scripts/install.sh
```

Manual equivalent:
```bash
cp cli/codo.ts ~/.codo/codo.ts && chmod 700 ~/.codo/codo.ts
cp hooks/claude-hook.sh ~/.codo/hooks/claude-hook.sh && chmod 755 ~/.codo/hooks/claude-hook.sh
cp -R .build/release/Codo.app ~/Applications/Codo.app
```

**IMPORTANT**: `codo.ts` and `claude-hook.sh` are COPIED (not symlinked). After modifying these files in the repo, you MUST re-copy them to `~/.codo/` for changes to take effect.

## Restart

### Full restart (app + guardian + socket)
```bash
pkill -f "Codo.app/Contents/MacOS/Codo" 2>/dev/null; sleep 1
open .build/release/Codo.app   # dev mode
# or: open ~/Applications/Codo.app   # installed mode
```

Guardian is auto-spawned by Codo.app on launch (if enabled in settings + API key present).

### Guardian-only restart
Killing guardian triggers auto-restart by Codo.app (1s delay, max 3 retries before disable):
```bash
pkill -f "guardian/main.ts"
```

### When to restart
| Changed file | Action needed |
|---|---|
| `guardian/*.ts` | Kill guardian: `pkill -f "guardian/main.ts"` (auto-restarts with new code) |
| `cli/codo.ts` | Copy to `~/.codo/`: `cp cli/codo.ts ~/.codo/codo.ts` |
| `hooks/claude-hook.sh` | Copy to `~/.codo/hooks/`: `cp hooks/claude-hook.sh ~/.codo/hooks/claude-hook.sh` |
| `Sources/**/*.swift` | Full rebuild + restart: `./scripts/build.sh && pkill -f Codo.app; sleep 1; open .build/release/Codo.app` |
| `guardian/package.json` | `cd guardian && bun install` then kill guardian |

## Verify

```bash
# Check processes
ps aux | grep -E "Codo.app|guardian/main" | grep -v grep

# Check socket
ls -la ~/.codo/codo.sock

# Send test notification
echo '{"title":"Test","body":"Hello"}' | bun ~/.codo/codo.ts

# Check logs
tail -f ~/.codo/guardian.log    # guardian stderr (TypeScript layer)
tail -f ~/.codo/hooks.log       # hook + CLI layer
```

## Testing

```bash
# All tests (Swift + TS + Guardian) — run by pre-commit hook
bun test                        # guardian tests only
cd cli && bun test              # CLI tests only
swift test                      # Swift tests only
```

## Key Paths

| Path | Purpose |
|---|---|
| `~/.codo/codo.sock` | Unix Domain Socket (daemon ↔ CLI) |
| `~/.codo/codo.ts` | Installed CLI (COPY from `cli/codo.ts`) |
| `~/.codo/hooks/claude-hook.sh` | Installed hook (COPY from `hooks/claude-hook.sh`) |
| `~/.codo/guardian.log` | Guardian stderr log |
| `~/.codo/hooks.log` | Hook + CLI diagnostic log |
| `.build/release/Codo.app` | Built app bundle (dev mode) |

## Environment Variables

Guardian reads from Codo.app settings (passed as env to subprocess):
- `CODO_PROVIDER` — AI provider (minimax, anthropic, custom, etc.)
- `CODO_API_KEY` — stored in Keychain
- `CODO_MODEL`, `CODO_BASE_URL`, `CODO_SDK_TYPE`, `CODO_CONTEXT_LIMIT`
- `CODO_DEBUG=1` — enable JSON structured logging in guardian

## Retrospective

### 2026-03-20: Notification chain silent failure
**Root cause**: `~/.codo/codo.ts` was v0.1.0 (no `--hook` support). The old CLI silently ignored `--hook` as an unknown flag, then failed with "title is required" (exit 1). The old `claude-hook.sh` had a `$?` bug that captured `echo`'s exit code (0) instead of the CLI's (1), masking the failure.

**Lesson**: After adding new CLI features (like `--hook`), MUST deploy to `~/.codo/codo.ts`. Files are copies, not symlinks. Added persistent `hooks.log` and `PIPESTATUS` fix to catch this class of error.

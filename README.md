# Codo

macOS menubar daemon + CLI for displaying system toast notifications. Designed as a notification bridge for Claude Code hooks and other AI agent workflows.

```bash
# Simple notification
codo "Build Done" "All 42 tests passed"

# With template (sets subtitle + sound automatically)
codo "Build Done" "42 tests passed" --template success
codo "Build Failed" "3 errors" --template error
codo "Deploying..." --template progress

# Group related notifications
codo "Step 1/3" --template progress --thread deploy-v1.2
codo "Step 2/3" --template progress --thread deploy-v1.2
codo "Deploy Done" --template success --thread deploy-v1.2

# Via stdin JSON
echo '{"title":"Build Done","body":"All tests passed","subtitle":"✅ Success"}' | codo

# List available templates
codo --template list
```

## Architecture

Two layers: **Swift menubar app** (daemon, listens on Unix Domain Socket, shows toast) + **TypeScript CLI** (Bun script, sends messages to daemon).

```
Claude Code hook → codo CLI (Bun) → UDS → Codo.app (Swift) → macOS notification
```

## Development

### Prerequisites

- **macOS 14+** (Sonoma)
- **Swift 5.10+** (`swift --version`)
- **Bun** (`bun --version`) — CLI runtime and TS test runner
- **SwiftLint** (`brew install swiftlint`)

### Setup

```bash
# Install dependencies and git hooks
bun install
```

This runs `husky` via the `prepare` script, which sets up `.husky/` as the git hooks directory.

### Git Hooks

| Hook | Stage | What runs |
|------|-------|-----------|
| **pre-commit** | Swift + TS unit tests, SwiftLint, Biome | `swift test` + `bun test` (cli, guardian) + lint |
| **pre-push** | same + UDS integration | also `scripts/integration-test.sh` |

`--no-verify` is forbidden. Every commit must pass unit tests and lint.

### Running Tests Manually

```bash
# Swift + TS unit tests
swift test
cd cli && bun test
cd guardian && bun test

# G1 lint
swiftlint lint --strict --quiet
cd cli && bunx biome check --error-on-warnings .
cd guardian && bunx biome check --error-on-warnings .

# UDS integration (pre-push)
./scripts/integration-test.sh

# Native UI checklist (manual)
./scripts/e2e-test.sh

# Swift coverage report (target: 90%+ on CodoCore)
swift test --enable-code-coverage
xcrun llvm-cov report \
  .build/debug/CodoPackageTests.xctest/Contents/MacOS/CodoPackageTests \
  --instr-profile=.build/debug/codecov/default.profdata \
  --sources Sources/CodoCore/
```

### Coverage

| Target | Current | Goal |
|--------|---------|------|
| CodoCore (testable) | 91% | ≥ 90% |
| CLI (parseArgs/parseStdin) | 100% | — |

`SystemNotificationProvider` is excluded from coverage — it requires a real `.app` bundle with `UNUserNotificationCenter` and is tested via L4 E2E manual checklist.

### Build & Install

```bash
# Build signed .app bundle
./scripts/build.sh

# Install to ~/Applications + symlink CLI to /usr/local/bin
./scripts/install.sh
```

## CLI Usage

```bash
codo <title> [body] [--template <name>] [--subtitle <text>] [--thread <id>] [--silent]
```

| Flag | Description |
|------|-------------|
| `--template <name>` | Apply a notification template (sets subtitle + sound) |
| `--subtitle <text>` | Set notification subtitle (overrides template) |
| `--thread <id>` | Group notifications by thread ID |
| `--silent` | Suppress notification sound (overrides template) |
| `--template list` | List all available templates |

### Templates

| Template | Subtitle | Sound | Use Case |
|----------|----------|-------|----------|
| `success` | ✅ Success | default | Build passed, tests green |
| `error` | ❌ Error | default | Build failed, test failures |
| `warning` | ⚠️ Warning | default | Lint warnings, deprecations |
| `info` | ℹ️ Info | none | Status updates (silent) |
| `progress` | 🔄 In Progress | none | Long-running tasks (silent) |
| `question` | ❓ Action Needed | default | User input required |
| `deploy` | 🚀 Deploy | default | Deployment lifecycle |
| `review` | 👀 Review | default | PR/code review requests |

## Claude Code Integration

Codo includes a hook script that receives all Claude Code events and routes them to the daemon. After installing, configure `~/.claude/settings.json` to point at the script:

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

Debug with `CODO_DEBUG_HOOKS=1` — output goes to stderr only, never blocks the agent. See [docs/features/04-claude-hook-integration.md](docs/features/04-claude-hook-integration.md) for the full design.

## Docs

See [docs/](docs/) for design documents:

- [Architecture](docs/architecture/) — System design, IPC protocol, build, testing, MVP plan
- [Features](docs/features/) — Feature iteration docs (notification templates)

# 01 - Notification Templates

> CLI-side template system for diverse notification styles across software development workflows.

## Problem

Codo 当前只有 `title/body/sound` 三个字段，所有通知看起来完全一样。Agent（Claude Code, Cursor, Copilot 等）在开发过程中有大量不同场景需要通知用户：构建成功/失败、测试进度、代码审查、部署完成、需要用户介入等。用户无法一眼区分通知的紧急程度和类型。

## Solution

新增 **template 系统**：CLI 内置一组预定义模板，通过 `--template <name>` 选择，自动设置 subtitle、sound、threadId 等字段。模板是 **CLI-only 概念**，daemon 侧只需透传新增字段到 `UNNotificationContent`。

## Design

### Template Definitions

Templates control **visual style only** (subtitle + sound). They do **not** set `threadId`.

| Template | Subtitle | Sound | Use Case |
|----------|----------|-------|----------|
| `success` | ✅ Success | `default` | Build passed, tests green, deploy done |
| `error` | ❌ Error | `default` | Build failed, test failures, crash |
| `warning` | ⚠️ Warning | `default` | Lint warnings, deprecations |
| `info` | ℹ️ Info | `none` | Status updates, progress (silent) |
| `progress` | 🔄 In Progress | `none` | Long-running task updates (silent) |
| `question` | ❓ Action Needed | `default` | User input required, approval needed |
| `deploy` | 🚀 Deploy | `default` | Deployment lifecycle |
| `review` | 👀 Review | `default` | PR ready, code review requests |

### threadId: Business Grouping Key

`threadId` is orthogonal to templates. It represents a **business domain** — the caller decides how to group notifications. Templates never set threadId.

```bash
# Same template (success), different business domains:
codo "Build Passed" --template success --thread build
codo "Deploy Done"  --template success --thread deploy
codo "PR Merged"    --template success --thread pr-42

# Same business domain, different templates:
codo "Deploying..." --template progress --thread deploy-v1.2
codo "Deploy Done"  --template success  --thread deploy-v1.2
codo "Deploy Failed" --template error   --thread deploy-v1.2
```

If `--thread` is omitted, `threadId` is `nil` and macOS applies its default grouping behavior.

### Agent Notification Scenarios

Templates cover these common agent workflows:

```bash
# Build lifecycle
codo "Build Complete" "42 tests passed in 3.2s" --template success --thread build
codo "Build Failed" "error in auth.swift:42" --template error --thread build

# Test progress (same thread groups the sequence)
codo "Running Tests" "14/42 suites..." --template progress --thread test-run
codo "Tests Passed" "42 suites, 0 failures" --template success --thread test-run
codo "3 Tests Failed" "see terminal for details" --template error --thread test-run

# Lint / static analysis
codo "Lint Clean" "0 errors, 0 warnings" --template success
codo "2 Lint Warnings" "unused import in api.ts" --template warning

# Deployment (thread groups deploy lifecycle)
codo "Deploying v1.2.0" "to production..." --template deploy --thread deploy-v1.2
codo "Deploy Complete" "v1.2.0 live on prod" --template success --thread deploy-v1.2
codo "Deploy Failed" "rollback initiated" --template error --thread deploy-v1.2

# Code review
codo "PR #42 Ready" "needs your review" --template review --thread pr-42
codo "PR #42 Approved" "all checks passed" --template success --thread pr-42

# Agent needs user input
codo "Input Needed" "approve database migration?" --template question
codo "Waiting for Auth" "open browser to continue" --template question

# Background task status
codo "Indexing..." "processing 1,247 files" --template info
codo "Index Complete" "1,247 files indexed" --template success
```

### Wire Format Changes

**Current** `CodoMessage`:
```json
{"title": "Build Done", "body": "All tests passed", "sound": "default"}
```

**New** `CodoMessage`:
```json
{
  "title": "Build Done",
  "body": "All tests passed",
  "subtitle": "✅ Success",
  "sound": "default",
  "threadId": "build"
}
```

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `title` | `String` | ✅ | — | Notification title (unchanged) |
| `body` | `String?` | ❌ | `nil` | Notification body (unchanged) |
| `subtitle` | `String?` | ❌ | `nil` | **NEW** — displayed below title, above body |
| `sound` | `String?` | ❌ | `"default"` | `"default"` or `"none"` (unchanged) |
| `threadId` | `String?` | ❌ | `nil` | **NEW** — groups notifications in Notification Center |

**Backward compatible** — old clients sending only `title/body/sound` still work. New fields are optional with `nil` defaults.

### Empty String Normalization

CLI normalizes `subtitle` and `threadId` before sending:

```
trim(value)  →  if empty → omit field (treat as nil)
```

- `--subtitle "  "` → subtitle omitted from JSON
- `--thread ""` → threadId omitted from JSON
- `{"subtitle": " ", "threadId": ""}` via stdin → both omitted

Daemon does **not** validate or normalize `subtitle` / `threadId`. It passes whatever it receives to `UNNotificationContent`. The CLI is the single normalization point.

### CLI Interface Changes

#### Usage

```bash
codo <title> [body] [--template <name>] [--subtitle <text>] [--thread <id>] [--silent]

# List available templates
codo --template list
```

#### Flag Parsing Rules

The current parser only recognizes `--silent` (boolean flag) and ignores all other `--xxx` tokens. The new parser must handle **value flags** (`--template <value>`, `--subtitle <value>`, `--thread <value>`) alongside the existing boolean flag (`--silent`).

**Parsing algorithm**:

```
for each token in argv:
  if token == "--silent"         → set silent = true
  if token == "--template"       → consume next token as template name
  if token == "--subtitle"       → consume next token as subtitle value
  if token == "--thread"         → consume next token as threadId value
  if token starts with "--"      → ignore (unknown flag, preserve current behavior)
  else                           → push to positional[]
```

**Error conditions**:
- `--template` / `--subtitle` / `--thread` at end of argv (no next token) → error: `"--<flag> requires a value"`
- `--template <unknown_name>` → error: `"unknown template: <name>"`
- `--template list` → print template table, exit 0 (special case, not a template name)

**Positional args**: `positional[0]` = title, `positional[1]` = body. Same as current.

#### Priority (field resolution order)

For each field, the first non-nil value wins:

```
subtitle:  --subtitle flag  >  template default  >  nil
sound:     --silent flag     >  template default  >  "default"
threadId:  --thread flag     >  nil  (templates never set threadId)
```

Note: `--silent` sets `sound = "none"`. If both `--silent` and a template with `sound: "default"` are given, `--silent` wins.

#### stdin JSON

stdin accepts only **wire-format fields**: `title`, `body`, `subtitle`, `sound`, `threadId`.

The `template` key is **not accepted** in stdin JSON. If present, it is silently ignored (same as any unknown field today). This keeps stdin as a direct wire-format pass-through — no expansion logic.

```bash
# ✅ Valid: wire fields only
echo '{"title":"Done","subtitle":"✅ Success","threadId":"build"}' | codo

# ⚠️ template key ignored, no expansion happens
echo '{"title":"Done","template":"success"}' | codo
# → sends {"title":"Done"} with no subtitle
```

### Template Expansion (CLI-side)

```typescript
interface TemplateDefaults {
  subtitle: string;
  sound: "default" | "none";
}

const TEMPLATES: Record<string, TemplateDefaults> = {
  success:  { subtitle: "✅ Success",       sound: "default" },
  error:    { subtitle: "❌ Error",          sound: "default" },
  warning:  { subtitle: "⚠️ Warning",       sound: "default" },
  info:     { subtitle: "ℹ️ Info",           sound: "none" },
  progress: { subtitle: "🔄 In Progress",   sound: "none" },
  question: { subtitle: "❓ Action Needed",  sound: "default" },
  deploy:   { subtitle: "🚀 Deploy",        sound: "default" },
  review:   { subtitle: "👀 Review",        sound: "default" },
};
```

Templates only set `subtitle` and `sound`. They never set `threadId` — that is always caller-specified via `--thread`.

Template is applied before sending to daemon. The `template` key is **not** transmitted over the wire — only the expanded fields are sent.

## File Changes

### Swift (daemon side)

#### `Sources/CodoCore/CodoMessage.swift`
- Add `subtitle: String?` and `threadId: String?` properties
- Update `init` to accept new parameters (default `nil`)
- `validate()` unchanged — still only checks title

```swift
public struct CodoMessage: Codable, Sendable {
    public let title: String
    public let body: String?
    public let subtitle: String?    // NEW
    public let sound: String?
    public let threadId: String?    // NEW

    public init(title: String, body: String? = nil, subtitle: String? = nil,
                sound: String? = nil, threadId: String? = nil) { ... }
}
```

#### `Sources/CodoCore/NotificationService.swift`
- Change `NotificationProvider.post()` to accept `CodoMessage` instead of `(title:body:sound:)`
- Simplifies the interface and avoids parameter explosion

```swift
// Before
func post(title: String, body: String?, sound: String) async -> String?

// After
func post(message: CodoMessage) async -> String?
```

- Update `NotificationService.post(message:)` to pass `CodoMessage` through

#### `Sources/CodoCore/SystemNotificationProvider.swift`
- Use `message.subtitle` → `content.subtitle`
- Use `message.threadId` → `content.threadIdentifier`

```swift
func post(message: CodoMessage) async -> String? {
    let content = UNMutableNotificationContent()
    content.title = message.title
    if let body = message.body { content.body = body }
    if let subtitle = message.subtitle { content.subtitle = subtitle }
    if let threadId = message.threadId { content.threadIdentifier = threadId }
    if message.effectiveSound == "default" { content.sound = .default }
    ...
}
```

### TypeScript (CLI side)

#### `cli/codo.ts`
- Add `TEMPLATES` constant with 8 template definitions
- Extend `CodoMessage` interface with `subtitle?` and `threadId?`
- `parseArgs()`: support `--template <name>`, `--subtitle <text>`, `--thread <id>` (value flags)
- `parseStdin()`: support `subtitle` and `threadId` wire fields; normalize empty/whitespace to `undefined`
- Add `applyTemplate()` function: merge template defaults with explicit flags (explicit wins)
- `--template list` prints available templates to stderr and exits 0

### Test Infrastructure

#### `Sources/CodoTestServer/CodoTestServer.swift`
- Add message logging: every received message is appended as a JSON line to a log file (`$SOCK_DIR/messages.log`)
- L3 tests send a message via CLI, then read the log file to assert on exact fields the server received
- This avoids changing the CLI's output contract (success = exit 0, no stdout)

**Why not echo via response?** The CLI only checks `response.ok` and exits — it never prints extra response fields to stdout. Changing that would break the "silent success" contract. Writing to a sidecar log file is the cleanest way to verify server-side field reception without altering the CLI.

### Tests

#### `Tests/CodoCoreTests/MessageCodecTests.swift`
- Encode/decode CodoMessage with subtitle and threadId
- Backward compat: decode JSON without new fields (defaults to nil)

#### `Tests/CodoCoreTests/NotificationServiceTests.swift`
- Update mock provider to new `post(message:)` signature
- Add test: subtitle and threadId passed through to provider

#### `cli/codo.test.ts`
- parseArgs: `--template success` sets subtitle and sound
- parseArgs: `--template error` sets error defaults
- parseArgs: `--template unknown` → error `"unknown template: unknown"`
- parseArgs: `--template` at end of argv → error `"--template requires a value"`
- parseArgs: `--subtitle "custom"` overrides template subtitle
- parseArgs: `--thread "my-project"` sets threadId
- parseArgs: `--thread` at end of argv → error
- parseArgs: `--silent` overrides template sound
- parseArgs: mixed positional and flags in any order
- parseStdin: subtitle and threadId fields parsed
- parseStdin: empty/whitespace subtitle and threadId → omitted (normalized to undefined)
- parseStdin: `template` key in JSON silently ignored
- applyTemplate: all 8 templates produce correct subtitle + sound

#### `scripts/integration-test.sh`

Current L3 harness only checks exit code and stderr, which cannot verify that the daemon received `subtitle`/`threadId` correctly. To enable real verification:

**CodoTestServer message log**: The test server appends every received `CodoMessage` as a JSON line to `$SOCK_DIR/messages.log`. L3 tests send a message via CLI, then read the last line of the log file to assert on fields.

```bash
# L3 test: subtitle + threadId roundtrip
echo '{"title":"LogTest","subtitle":"✅ test","threadId":"t1"}' \
  | HOME="$FAKE_HOME" bun "$CLI" 2>/dev/null
# Read last logged message from server's sidecar log
LAST=$(tail -1 "$SOCK_DIR/messages.log")
echo "$LAST" | jq -e '.subtitle == "✅ test" and .threadId == "t1"'
```

New L3 tests:
- `--template list` → exit 0, stderr contains "success" and "error"
- subtitle+threadId roundtrip via message log (verify server received fields)
- template expansion roundtrip: `--template success` → server log shows subtitle "✅ Success"

## Atomic Commits

| # | Type | Message | Status |
|---|------|---------|--------|
| 1 | `docs` | `docs: add notification templates design` | ✅ Done (098f679) |
| 2 | `docs` | `docs: tighten template design spec` | ✅ Done (2aa5b63) |
| 3 | `docs` | `docs: fix L3 verification and sync protocol docs` | ✅ Done (5842fb4) |
| 4 | `feat` | `feat: extend CodoMessage with subtitle and threadId` | ✅ Done (40e89de) |
| 5 | `refactor` | `refactor: change NotificationProvider to accept CodoMessage` | ✅ Done (a7200c5) |
| 6 | `feat` | `feat: add message logging to CodoTestServer` | ✅ Done (f22b266) |
| 7 | `feat` | `feat: add template system to CLI` | ✅ Done (2b87fc2) |
| 8 | `test` | `test: add template integration tests` | ✅ Done (17645ea) |
| 9 | `fix` | `fix: serialize test server log writes and reject flags as values` | ✅ Done (7621537) |
| 10 | `fix` | `fix: add asset catalog so notification banners show app icon` | ✅ Done (fe5ff00) |

**Note**: Commit 6 (`feat: apply subtitle and threadId in SystemNotificationProvider`) was folded into commit 5 — the provider refactor and new field application were done together since they were tightly coupled.

## Verification

```bash
# L1: Swift unit tests
swift test

# L1: TypeScript unit tests
cd cli && bun test

# L2: Lint
swiftlint lint --strict --quiet
cd cli && bunx biome check .

# L3: Integration
bash scripts/integration-test.sh

# L4: Manual (build + launch + test each template visually)
bash scripts/build.sh && open .build/release/Codo.app
bun cli/codo.ts "Build Done" "42 tests" --template success --thread build
bun cli/codo.ts "Build Failed" "3 errors" --template error --thread build
bun cli/codo.ts "Step 1/3" --template progress --thread long-task
bun cli/codo.ts "Step 2/3" --template progress --thread long-task
bun cli/codo.ts "All Done" --template success --thread long-task
bun cli/codo.ts "PR Ready" "review please" --template review --thread pr-42
bun cli/codo.ts --template list

# Verify: same --thread notifications group together in Notification Center
# Verify: different --thread notifications stay separate
# Verify: --silent overrides template sound
bun cli/codo.ts "Silent Success" --template success --silent
```

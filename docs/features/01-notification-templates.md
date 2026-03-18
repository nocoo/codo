# 01 - Notification Templates

> CLI-side template system for diverse notification styles across software development workflows.

## Problem

Codo 当前只有 `title/body/sound` 三个字段，所有通知看起来完全一样。Agent（Claude Code, Cursor, Copilot 等）在开发过程中有大量不同场景需要通知用户：构建成功/失败、测试进度、代码审查、部署完成、需要用户介入等。用户无法一眼区分通知的紧急程度和类型。

## Solution

新增 **template 系统**：CLI 内置一组预定义模板，通过 `--template <name>` 选择，自动设置 subtitle、sound、threadId 等字段。模板是 **CLI-only 概念**，daemon 侧只需透传新增字段到 `UNNotificationContent`。

## Design

### Template Definitions

| Template | Subtitle | Sound | ThreadId | Use Case |
|----------|----------|-------|----------|----------|
| `success` | ✅ Success | `default` | `codo.result` | Build passed, tests green, deploy done |
| `error` | ❌ Error | `default` | `codo.result` | Build failed, test failures, crash |
| `warning` | ⚠️ Warning | `default` | `codo.result` | Lint warnings, deprecations |
| `info` | ℹ️ Info | `none` | `codo.info` | Status updates, progress (silent) |
| `progress` | 🔄 In Progress | `none` | `codo.progress` | Long-running task updates (silent) |
| `question` | ❓ Action Needed | `default` | `codo.action` | User input required, approval needed |
| `deploy` | 🚀 Deploy | `default` | `codo.deploy` | Deployment lifecycle |
| `review` | 👀 Review | `default` | `codo.review` | PR ready, code review requests |

### Agent Notification Scenarios

Templates cover these common agent workflows:

```bash
# Build lifecycle
codo "Build Complete" "42 tests passed in 3.2s" --template success
codo "Build Failed" "error in auth.swift:42" --template error

# Test progress
codo "Running Tests" "14/42 suites..." --template progress
codo "Tests Passed" "42 suites, 0 failures" --template success
codo "3 Tests Failed" "see terminal for details" --template error

# Lint / static analysis
codo "Lint Clean" "0 errors, 0 warnings" --template success
codo "2 Lint Warnings" "unused import in api.ts" --template warning

# Deployment
codo "Deploying v1.2.0" "to production..." --template deploy
codo "Deploy Complete" "v1.2.0 live on prod" --template success
codo "Deploy Failed" "rollback initiated" --template error

# Code review
codo "PR #42 Ready" "needs your review" --template review
codo "PR #42 Approved" "all checks passed" --template success

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
  "threadId": "codo.result"
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

### CLI Interface Changes

```bash
# Template flag (NEW)
codo <title> [body] [--template <name>] [--silent] [--subtitle <text>] [--thread <id>]

# List available templates
codo --template list

# Template sets defaults, explicit flags override
codo "Done" --template success --subtitle "Custom"  # subtitle = "Custom", not "✅ Success"
```

**Priority**: explicit flag > template default > global default

### Template Expansion (CLI-side)

```typescript
const TEMPLATES: Record<string, Partial<CodoMessage>> = {
  success:  { subtitle: "✅ Success",       sound: "default", threadId: "codo.result" },
  error:    { subtitle: "❌ Error",          sound: "default", threadId: "codo.result" },
  warning:  { subtitle: "⚠️ Warning",       sound: "default", threadId: "codo.result" },
  info:     { subtitle: "ℹ️ Info",           sound: "none",    threadId: "codo.info" },
  progress: { subtitle: "🔄 In Progress",   sound: "none",    threadId: "codo.progress" },
  question: { subtitle: "❓ Action Needed",  sound: "default", threadId: "codo.action" },
  deploy:   { subtitle: "🚀 Deploy",        sound: "default", threadId: "codo.deploy" },
  review:   { subtitle: "👀 Review",        sound: "default", threadId: "codo.review" },
};
```

Template is applied before sending to daemon. The `template` field is **not** transmitted over the wire — only the expanded `subtitle`, `sound`, `threadId` are sent.

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
- `parseArgs()`: support `--template <name>`, `--subtitle <text>`, `--thread <id>`
- `parseStdin()`: support `subtitle` and `threadId` fields
- Add `applyTemplate()` function for merging template defaults with explicit values
- `--template list` prints available templates and exits

### Tests

#### `Tests/CodoCoreTests/MessageCodecTests.swift`
- Encode/decode CodoMessage with subtitle and threadId
- Backward compat: decode JSON without new fields (defaults to nil)

#### `Tests/CodoCoreTests/NotificationServiceTests.swift`
- Update mock provider to new `post(message:)` signature
- Add test: subtitle and threadId passed through to provider

#### `cli/codo.test.ts`
- parseArgs: `--template success` sets subtitle/sound/threadId
- parseArgs: `--template error` sets error defaults
- parseArgs: `--template unknown` → error
- parseArgs: explicit `--subtitle` overrides template
- parseArgs: explicit `--thread` overrides template
- parseArgs: `--template` without value → error
- parseStdin: subtitle and threadId fields parsed
- template expansion: all 8 templates produce correct defaults

#### `scripts/integration-test.sh`
- Add test: template message roundtrip (subtitle + threadId)
- Add test: `--template list` exits 0

## Atomic Commits

| # | Type | Message | Content |
|---|------|---------|---------|
| 1 | `docs` | `docs: add notification templates design` | This file + update `docs/features/README.md` + `docs/README.md` index |
| 2 | `feat` | `feat: extend CodoMessage with subtitle and threadId` | Swift model + encode/decode tests |
| 3 | `refactor` | `refactor: change NotificationProvider to accept CodoMessage` | Protocol change + mock update + all existing tests pass |
| 4 | `feat` | `feat: apply subtitle and threadId in SystemNotificationProvider` | Real provider uses new fields |
| 5 | `feat` | `feat: add template system to CLI` | TS templates + parseArgs/parseStdin + template logic + TS tests |
| 6 | `test` | `test: add template integration tests` | L3 roundtrip + --template list |
| 7 | `docs` | `docs: update protocol docs for new fields` | Update `02-ipc-protocol.md` wire format |

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
bun cli/codo.ts "Build Done" "42 tests" --template success
bun cli/codo.ts "Build Failed" "3 errors" --template error
bun cli/codo.ts "Step 1/3" --template progress
bun cli/codo.ts --template list
```

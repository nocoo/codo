# 01 - System Design

> Codo — Two-layer system: a Swift macOS menubar daemon + a TypeScript CLI. Claude Code hooks call the CLI, which sends messages to the daemon via Unix Domain Socket, and the daemon displays macOS toast notifications.

## Overview

Two separate programs:

1. **Swift menubar app** (`Codo.app`) — daemon, listens on UDS, shows toast
2. **TypeScript CLI** (`codo`) — Bun script, reads args/stdin, sends to UDS

### Call Flow

```
Claude Code hook
    │
    ▼
codo CLI (TypeScript / Bun)
    │  codo "Build Done" "All tests passed"
    │  — or —
    │  echo '{"_hook":"stop",...}' | codo --hook stop
    ▼
Unix Domain Socket (~/.codo/codo.sock)
    │
    ▼
Codo.app (Swift menubar daemon)
    │
    ├─── CodoMessage (no _hook) ──► UNUserNotificationCenter → macOS toast
    │
    └─── Hook Event (_hook present) ──► Guardian Pipeline
         │                                │
         ├── Guardian ON ─► bun guardian/main.ts (stdin/stdout)
         │                    │  classify → LLM → send/suppress
         │                    ▼
         │                  GuardianAction → UNUserNotificationCenter
         │
         └── Guardian OFF ─► FallbackNotification → UNUserNotificationCenter
```

## Architecture

### Two Layers + Guardian, Clear Boundary

```
┌─────────────────────────────────────────────────┐
│  Layer 1: Swift Menubar App (Codo.app)          │
│                                                 │
│  - NSStatusItem with custom template image       │
│  - SocketServer listening on UDS                │
│  - MessageRouter: CodoMessage vs Hook Event     │
│  - NotificationService → UNUserNotificationCenter│
│  - GuardianProcess: spawns bun guardian/main.ts  │
│  - Settings window (API key, model, base URL)   │
│  - FallbackNotification (when Guardian is OFF)  │
│  - Right-click menu (version, settings, quit)   │
│  - Runs as .app bundle only                     │
└──────────────────────┬──────────────────────────┘
                       │ UDS: ~/.codo/codo.sock
┌──────────────────────┴──────────────────────────┐
│  Layer 2: TypeScript CLI (cli/codo)             │
│                                                 │
│  - Bun script, no build step                    │
│  - Accepts args or stdin JSON                   │
│  - --hook flag for Claude Code hook events      │
│  - Connects to UDS, sends request, reads response│
│  - Exit code reflects success/failure           │
└─────────────────────────────────────────────────┘
                       │ stdin/stdout pipes
┌──────────────────────┴──────────────────────────┐
│  Layer 3: Guardian (guardian/main.ts)            │
│                                                 │
│  - Spawned by daemon as child process           │
│  - Reads hook events from stdin (JSON lines)    │
│  - Event classifier (important/contextual/noise)│
│  - Project state tracking (per cwd)             │
│  - LLM client (OpenAI-compatible, tool_choice)  │
│  - Writes GuardianAction to stdout (send/suppress)│
│  - Fallback on LLM timeout/error                │
└─────────────────────────────────────────────────┘
```

**Why this split?**
- Swift side: daemon, notification delivery, Guardian process management
- TS CLI side: no compilation, easy to modify, natural for hook scripts
- Guardian side: LLM-powered intelligence, isolated process (crash-safe), easy to iterate
- Clear IPC contracts — layers can evolve independently

### Repository Structure

```
codo/
├── Package.swift                    ← Swift project (daemon only)
├── Sources/
│   ├── CodoCore/                   ← Business logic, zero AppKit dependency
│   │   ├── CodoMessage.swift       ← Message + Response types
│   │   ├── SocketServer.swift      ← UDS listener
│   │   ├── NotificationService.swift ← UNUserNotificationCenter wrapper
│   │   ├── MessageRouter.swift     ← Discriminated union dispatch
│   │   ├── GuardianProcess.swift   ← Child process manager (spawn, restart, pipes)
│   │   ├── GuardianSettings.swift  ← UserDefaults + Keychain persistence
│   │   ├── KeychainService.swift   ← Keychain read/write
│   │   └── FallbackNotification.swift ← Hook → CodoMessage when Guardian OFF
│   ├── Codo/                       ← Thin app shell
│   │   ├── AppDelegate.swift       ← NSStatusItem, menu, wiring
│   │   ├── SettingsWindow.swift    ← Programmatic NSWindow for Guardian config
│   │   └── SettingsViewModel.swift ← @Published bindings for settings UI
│   └── CodoTestServer/             ← Minimal test server for L3 integration
│       └── CodoTestServer.swift
├── Tests/
│   └── CodoCoreTests/              ← L1 unit tests (swift test)
├── cli/                            ← TypeScript CLI
│   ├── codo.ts                     ← Main script (Bun executable)
│   ├── codo.test.ts                ← CLI tests (bun test)
│   └── package.json                ← Metadata only (no deps needed)
├── guardian/                       ← AI Guardian (TypeScript)
│   ├── main.ts                     ← Entry point: stdin/stdout JSON lines
│   ├── types.ts                    ← Shared types (HookEvent, GuardianAction, etc.)
│   ├── classifier.ts              ← Event tier classification
│   ├── state.ts                   ← Project state tracking + event buffer
│   ├── llm.ts                     ← LLM client + prompt assembly
│   ├── fallback.ts                ← Fallback notifications (no LLM)
│   ├── *.test.ts                  ← Unit tests per module
│   ├── package.json               ← Dependencies (openai)
│   └── biome.json                 ← Linter config
├── Resources/
│   ├── Info.plist                  ← App bundle metadata
│   ├── AppIcon.icns                ← App icon (fallback)
│   ├── Assets.xcassets/            ← Asset Catalog (notification banner icon)
│   ├── menubar.png                 ← Menubar template image (18×18)
│   └── menubar@2x.png             ← Menubar template image (36×36)
├── scripts/
│   ├── build.sh                    ← Build + assemble + sign .app
│   ├── install.sh                  ← Install .app + symlink CLI
│   ├── integration-test.sh         ← L3 integration tests
│   └── e2e-test.sh                ← L4 semi-automated E2E tests
└── docs/
```

## Layer 1: Swift Menubar App

### Entry Point

```swift
@main struct CodoApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // no Dock icon
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
```

Manual `NSApplication` lifecycle (from Owl, proven stable). No SwiftUI views, no `MenuBarExtra`.

### Components

#### AppDelegate

- Creates `NSStatusItem` with custom template image (`menubar.png`, `isTemplate = true`)
- Falls back to SF Symbol `bell` if image not found in bundle
- Owns `SocketServer` and `NotificationService`
- Provides right-click `NSMenu`

#### Right-Click Menu

| Item | State | Notes |
|------|-------|-------|
| **Codo v0.1.0** | Disabled label | Version from `CodoInfo.version` |
| ─── | Separator | |
| **AI Guardian** | Checkbox | Toggle Guardian on/off (requires API key) |
| **Settings...** | — | Opens `SettingsWindowController` |
| ─── | Separator | |
| **Launch at Login** | Checkbox (off) | `SMAppService.mainApp` toggle |
| ─── | Separator | |
| **Quit Codo** | — | `NSApplication.shared.terminate(nil)` |

#### SocketServer

- Bind to `~/.codo/codo.sock` (mode `0600`, dir mode `0700`)
- Accept connection → read JSON + `\n` → decode → call NotificationService → encode response → send → close
- Request/response protocol, one exchange per connection
- See [02-ipc-protocol.md](02-ipc-protocol.md) for wire details

#### NotificationService

- On daemon startup: `requestAuthorization(options: [.alert, .sound])`
- `isAvailable` guard: `Bundle.main.bundleIdentifier != nil`

> **CRITICAL GOTCHA** (from Owl): `UNUserNotificationCenter.current()` crashes when `bundleIdentifier` is nil (SPM debug builds). MUST guard before any call. The guard is a **development-only safety net** — production always runs as `.app` bundle. When hit, returns `ok: false, "notifications unavailable (no app bundle)"`.

#### Permission Model

| Event | Action |
|-------|--------|
| Daemon startup (`.app` bundle) | `requestAuthorization(options: [.alert, .sound])` |
| Daemon startup (bare binary) | Skip, log warning to stderr |
| Message received, permission granted | Post notification, respond `ok: true` |
| Message received, permission denied | Respond `ok: false, error: "notification permission denied"` |
| System Focus / DND active | Respond `ok: true` — submitted to system, display is macOS's decision |

### MenuBar Icon

**Custom template image** (`Resources/menubar.png` / `menubar@2x.png`), `isTemplate = true`.

- Loaded via `Bundle.main.image(forResource: "menubar")`
- Falls back to SF Symbol `bell` if bundle image not found
- `isTemplate = true` — auto-adapts to light/dark menu bar
- Never draw SF Symbol into canvas for template icons (Owl lesson)
- Never use `contentTintColor` — pollutes button title text (Owl lesson)
- MVP: static icon only. Badge states are future work.

### App Lifecycle

**Launch**:
1. Create `~/.codo/` (mode `0700`) if missing
2. Stale socket check: if `.sock` exists, try `connect()` — success means another instance, exit; failure means stale, `unlink()`
3. Bind SocketServer
4. Request notification permission
5. Enter NSApplication run loop

**Shutdown** (terminate / SIGTERM / SIGINT):
1. Close SocketServer
2. Remove `~/.codo/codo.sock`
3. Exit

**Launch at Login**: `SMAppService.mainApp` (macOS 13+)

### Module Structure

```
Package.swift
├── CodoCore        (.target)          ← Business logic, zero AppKit
│   ├── MessageRouter                   ← Discriminated union dispatch
│   ├── GuardianProcess                 ← Child process manager
│   ├── GuardianSettings + Keychain     ← Persistence
│   └── FallbackNotification            ← Hook → CodoMessage fallback
├── Codo            (.executableTarget) ← App shell, depends on CodoCore
│   ├── SettingsWindow                  ← NSWindow for Guardian config
│   └── SettingsViewModel               ← @Published bindings
├── CodoTestServer  (.executableTarget) ← Test server for L3 integration
└── CodoCoreTests   (.testTarget)      ← Tests, depends on CodoCore
```

## Layer 2: TypeScript CLI

### Usage

```bash
# Positional args (most common in hooks)
codo "Build Done"                          # title only
codo "Build Done" "All 42 tests passed"   # title + body
codo "Build Done" "Passed" --silent        # no sound

# Templates (set subtitle + sound automatically)
codo "Build Done" "Passed" --template success
codo "Build Failed" "3 errors" --template error
codo "Deploying..." --template progress

# Custom subtitle and thread grouping
codo "PR Ready" --subtitle "Review" --thread pr-42

# Hook events (Claude Code integration)
echo '{"_hook":"stop","session_id":"s1","cwd":"/tmp","last_assistant_message":"Done"}' | codo --hook stop

# Stdin JSON (advanced)
echo '{"title":"Build Done","body":"Passed","subtitle":"✅ Success"}' | codo

# Flags
codo --help
codo --version
codo --template list
```

### Implementation

`cli/codo.ts` — single file, Bun shebang:

```typescript
#!/usr/bin/env bun
```

Logic:
1. `--help` / `--version` → print and exit (checked first, regardless of stdin)
2. If positional args present → use args as title/body (**args always win over stdin**)
3. Else if stdin is piped (`!Bun.stdin.isTTY`) → read JSON from stdin
4. Else (no args, no stdin) → print usage, exit(1)
5. Construct `CodoMessage` JSON
6. Connect to `~/.codo/codo.sock` (Bun native Unix socket)
7. Send JSON + `\n`, read response
8. On success: exit 0, **no stdout** (silent success)
9. On failure: print error to stderr, exit with code

**Edge cases**:
| Scenario | Behavior |
|----------|----------|
| `echo '{"title":"A"}' \| codo "B"` | Args win → title is "B" (stdin ignored) |
| `echo '{"title":"A"}' \| codo --help` | `--help` wins |
| `echo '' \| codo` | No args, piped stdin, empty → error exit(1) |
| `codo` (no args, tty) | Print usage, exit(1) |

### Output Contract

| Condition | stdout | stderr | Exit |
|-----------|--------|--------|------|
| Success (`ok:true`) | *(nothing)* | *(nothing)* | 0 |
| Daemon error (`ok:false`) | *(nothing)* | error string from daemon | 1 |
| Bad args / empty input | *(nothing)* | error message | 1 |
| Daemon not running | *(nothing)* | `codo daemon not running` | 2 |
| Connection error | *(nothing)* | error message | 3 |

CLI never writes to stdout. Success = exit 0 + silence. Errors go to stderr.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | `ok: true` — notification submitted |
| 1 | Client error: invalid args, bad JSON, or daemon returned `ok: false` |
| 2 | Daemon not running (socket missing) |
| 3 | Communication error (refused, timeout) |

### Install

```bash
./scripts/install.sh
# Copies codo.ts to ~/.codo/codo.ts, symlinks /usr/local/bin/codo
```

Requires Bun runtime installed on the machine.

## Message Schema

```typescript
// Request (CLI → Daemon)
interface CodoMessage {
  title: string;       // required
  body?: string;       // optional
  subtitle?: string;   // optional — displayed below title, above body
  sound?: "default" | "none"; // default: "default"
  threadId?: string;   // optional — groups notifications in Notification Center
}

// Response (Daemon → CLI)
interface CodoResponse {
  ok: boolean;
  error?: string;    // present when ok=false
}
```

`ok: true` = daemon accepted and submitted to `UNUserNotificationCenter`. Does NOT guarantee user saw the toast (Focus/DND may suppress).

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Two-layer split | Swift daemon + TS CLI | Each layer does one thing well, no mode detection |
| IPC | Unix Domain Socket | Low latency, local isolation, Bun has native support |
| CLI runtime | Bun | No build step, fast startup, native UDS support |
| CLI interface | Positional args + stdin JSON | Args for hooks (simple), stdin for programmatic use |
| Swift build | SPM only | No Xcode dependency, `swift build` workflow |
| App entry | Manual `NSApplication` | Full control, no SwiftUI needed |
| Notification | UNUserNotificationCenter | Native macOS toast, respects DND |
| Permission | Request at daemon startup | Avoid first-notification latency |
| Icon | Custom template image | Hummingbird logo, `isTemplate` for auto light/dark |
| Login item | SMAppService | macOS 13+ native |
| Instance check | Socket connectivity test | Sufficient, no flock/PID |

## Constraints

- **macOS 14+** (Sonoma)
- **No Sandbox** — UDS needs filesystem access
- **No App Store** — direct distribution
- **Bun required** — CLI depends on Bun runtime
- **Production = .app bundle** — bare Swift binary cannot show notifications

## Non-Goals (v1)

- Custom notification actions (buttons)
- Notification history / log viewer
- Rich media in notifications
- TCP/HTTP IPC

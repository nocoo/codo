# 01 - System Design

> Codo — macOS menubar resident app providing a CLI interface for local Claude Code hooks to display system toast notifications.

## Overview

Codo is a **pure Swift menubar app** that:

1. Displays a persistent **SF Symbol icon** in the macOS status bar
2. Listens on a **Unix Domain Socket** for incoming messages
3. Maps received messages to **macOS system toast notifications** via `UNUserNotificationCenter`
4. Provides a **CLI mode** (same binary) that sends JSON messages to the socket

### Call Flow

```
Claude Code hook
    │
    ▼
codo CLI (stdin JSON)
    │  echo '{"title":"Build Done","body":"All tests passed"}' | codo
    ▼
Unix Domain Socket (~/.codo/codo.sock)
    │
    ▼
codo menubar app (resident daemon)
    │
    ▼
macOS UNUserNotificationCenter → system toast
```

## Architecture

### Single Binary, Dual Mode

One SPM executable target, mode determined by stdin/arguments:

```
echo '{}' | codo  ← stdin detected    → CLI mode: send to socket, exit
codo --help       ← flag              → print usage, exit
codo --version    ← flag              → print version, exit
codo              ← no stdin, no args → (see "Daemon Entry" below)
```

**Why single binary?** Simpler installation (one file to copy), shared types between CLI and daemon, no version mismatch risk.

### Daemon Entry — PENDING DECISION

> **Status: 待定，不阻塞 MVP。**
>
> 运行裸 `codo` 时直接进入 NSApplication run loop，终端会被前台阻塞，交互体验不佳。
> 日常使用应通过 `open /Applications/Codo.app` 或 Login Item 启动。
>
> 可选方案（后续定稿）：
> 1. 裸 `codo` 直接报错，强制要求通过 `.app` 启动
> 2. 裸 `codo` 检测到 tty 时打印提示后 fork 到后台
> 3. 保持现状，接受终端阻塞行为
>
> **MVP 阶段**：daemon 仅通过 `open Codo.app` 启动。CLI 模式通过 `echo '...' | codo` 调用。`codo` 裸调用的行为暂不定义。

### Mode Detection — Precise Rules

```swift
// Priority order, first match wins:
// 1. Explicit flags
if hasFlag("--help")    → print usage, exit(0)
if hasFlag("--version") → print version, exit(0)

// 2. Stdin detection (non-interactive pipe)
if !isatty(STDIN_FILENO) {
    // Piped input detected. Read stdin with 5s timeout.
    // Empty stdin (e.g. from /dev/null) → error "empty input", exit(1)
    // Valid JSON → CLI mode: send to socket
    // Invalid JSON → error "invalid json", exit(1)
}

// 3. Interactive terminal, no flags
// → daemon mode (launch NSApplication)
```

**Edge cases**:
| Scenario | Behavior |
|----------|----------|
| `echo '{}' \| codo --help` | `--help` wins (flags checked first) |
| `codo < /dev/null` | `isatty=false`, read stdin → empty → error exit(1) |
| `echo '' \| codo` | `isatty=false`, read stdin → empty → error exit(1) |
| `cat msg.json \| codo` | CLI mode |
| `codo` in terminal | Daemon mode |
| `codo` in launch agent | Daemon mode (stdin is not a tty) — **needs special handling, see PENDING DECISION** |

### Module Structure

```
Package.swift
├── CodoCore        (.target)            — Shared types, socket protocol, message codec
│                                          Zero AppKit/UI dependency, fully testable
├── Codo            (.executableTarget)   — Entry point, mode router, AppKit menubar shell
│                                          depends on CodoCore
└── CodoTests       (.testTarget)        — Unit + integration tests
                                           depends on CodoCore
```

**Key principle**: `CodoCore` contains all business logic with zero UI dependency (mirroring Owl's `OwlCore` pattern). The executable target is a thin shell.

## Components

### 1. MenuBar Daemon (`MenuBarController`)

Responsibilities:
- Create `NSStatusItem` with SF Symbol icon
- Manage `NSApplication` lifecycle (`.accessory` policy — no Dock icon)
- Own the `SocketServer` instance
- Provide right-click context menu

**Entry point pattern** (from Owl, proven stable):

```swift
@main struct CodoApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
```

> **Why not SwiftUI `MenuBarExtra`?** We need precise control over NSApplication lifecycle and don't need SwiftUI views. The manual `NSApplication` approach is simpler for a notification-only app.

#### Right-Click Menu

| Item | Default State | Notes |
|------|---------------|-------|
| **Codo v0.1.0** | Disabled (info label) | Shows version |
| ─── | Separator | |
| **Launch at Login** | Off (unchecked) | Toggle `SMAppService.mainApp`. Requires `.app` bundle. Grayed out + tooltip if running as bare binary |
| ─── | Separator | |
| **Quit Codo** | — | `NSApplication.shared.terminate(nil)` |

### 2. Socket Server (`SocketServer`)

Responsibilities:
- Create and listen on Unix Domain Socket at `~/.codo/codo.sock`
- Accept connections, read JSON, post notification, **send response**, close connection
- Forward decoded `CodoMessage` to `NotificationService`
- Handle socket cleanup on app exit (delete `.sock` file)

**Socket path**: `~/.codo/codo.sock`
- `~/.codo/` directory created on first launch if missing
- Stale socket removed on startup via connectivity test (see [02-ipc-protocol.md](02-ipc-protocol.md))

**Protocol**: request/response, one exchange per connection. See [02-ipc-protocol.md](02-ipc-protocol.md) for wire format.

### 3. CLI Client (`CLIClient`)

Responsibilities:
- Read JSON from stdin (with 5s timeout)
- Validate message structure locally (fast-fail before connecting)
- Connect to Unix Domain Socket
- Send message, **read response**, exit with appropriate code

**Exit codes**:
| Code | Meaning |
|------|---------|
| 0 | `ok: true` received — daemon accepted and submitted to notification system |
| 1 | Client-side error: invalid JSON, missing fields, empty input, or `ok: false` from daemon |
| 2 | Daemon not running: socket file missing |
| 3 | Communication error: connection refused, timeout, unexpected response |

### 4. Notification Service (`NotificationService`)

Responsibilities:
- **Request notification permission on daemon startup** (not lazily on first use)
- Map `CodoMessage` to `UNNotificationContent`
- Post via `UNUserNotificationCenter`
- Report success/failure back to caller for socket response

#### Permission Model

| Event | Action |
|-------|--------|
| Daemon startup (in `.app` bundle) | Call `requestAuthorization(options: [.alert, .sound])` |
| Daemon startup (bare binary, no bundleIdentifier) | Skip — `UNUserNotificationCenter` is unavailable. Log warning to stderr |
| CLI sends message, permission granted | Post notification, respond `ok: true` |
| CLI sends message, permission denied by user | Respond `ok: false, error: "notification permission denied"` |
| CLI sends message, permission not determined | Unlikely (requested at startup), but treat as denied |
| System Focus / Do Not Disturb active | Respond `ok: true` — daemon successfully submitted to the notification system. macOS decides display policy; that's outside our control |

> **CRITICAL GOTCHA** (from Owl): `UNUserNotificationCenter.current()` crashes with `NSInternalInconsistencyException` when `Bundle.main.bundleIdentifier` is nil. This happens in SPM debug builds (`swift run`). **All UNUserNotificationCenter calls MUST guard `bundleIdentifier != nil`**.

```swift
enum NotificationService {
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }
}
```

#### Bare Binary Behavior

When running as bare binary (`swift run`, no `.app` bundle):
- `NotificationService.isAvailable` returns `false`
- Socket server still runs and accepts messages
- Responses: `ok: false, error: "notifications unavailable (no app bundle)"`
- This is **development-only**; production always runs as `.app`

### 5. Message Schema (`CodoMessage`)

```swift
struct CodoMessage: Codable {
    let title: String          // required — notification title
    let body: String?          // optional — notification body text
    let sound: String?         // optional — "default" | "none", defaults to "default"
}
```

**CLI usage**:

```bash
# Full message
echo '{"title":"Build Done","body":"All 42 tests passed","sound":"default"}' | codo

# Minimal (title only)
echo '{"title":"Build Done"}' | codo

# No sound
echo '{"title":"Deploying...","body":"ETA 2min","sound":"none"}' | codo
```

## MenuBar Icon

**SF Symbol: `bell`**

- `isTemplate = true` — macOS auto-adapts to light/dark menu bar
- Return raw SF Symbol directly, never draw into custom `NSImage` canvas for template icons (Owl lesson)
- Never use `button.contentTintColor` — it also tints `button.title` text (Owl lesson)

### Icon States (future, non-MVP)

| State | Icon | Template |
|-------|------|----------|
| Idle (daemon running) | `bell` | true |
| Recent notification | `bell.badge` | true |

Badge state auto-clears after 5 seconds. **MVP uses static `bell` only.**

## App Lifecycle

### Launch (Daemon Mode)

1. Create `~/.codo/` directory if missing (mode `0700`)
2. Check for existing instance:
   - If `~/.codo/codo.sock` exists → attempt `connect()`
   - If connect succeeds → another instance running → print error, exit
   - If connect fails → stale socket → `unlink()`, proceed
3. Bind `SocketServer` to `~/.codo/codo.sock` (mode `0600`)
4. Launch `NSApplication` with `.accessory` policy
5. Request notification permission (if `.app` bundle)

### Shutdown

1. `NSApplication.terminate` / SIGTERM / SIGINT
2. Close socket server (stop accepting)
3. Remove socket file (`~/.codo/codo.sock`)
4. Exit

### Launch at Login

- `SMAppService.mainApp` (macOS 13+, from both Owl and Gecko)
- Toggle via right-click menu
- Requires `.app` bundle — menu item disabled when running as bare binary

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Build system | SPM only | Owl pattern, `swift build` workflow, no Xcode dependency |
| App entry | Manual `NSApplication` | More control than `MenuBarExtra`, no SwiftUI views needed |
| Single binary | CLI + daemon in one | Simple install, shared types, no version mismatch |
| IPC | Unix Domain Socket | Low latency, local isolation, supports structured messages |
| IPC protocol | Request/response with JSON ack | CLI gets explicit success/failure, enables error reporting |
| Message format | stdin JSON | Flexible for hook scripts, no argument parsing complexity |
| Notification | UNUserNotificationCenter | Native macOS toast, respects Do Not Disturb |
| Permission timing | Daemon startup | Avoid first-notification latency, user sees prompt immediately |
| `ok: true` semantics | Submitted to notification system | Not "user saw it" — Focus/DND is outside our control |
| Icon | SF Symbol `bell` | No design asset needed, auto light/dark adaptation |
| Login item | SMAppService | macOS 13+ native, no helper app needed |
| Instance detection | Socket connectivity test | Simpler than flock/PID file, sufficient for this project |

## Constraints & Assumptions

- **macOS 14+** (Sonoma) — aligns with Owl's target, modern Swift concurrency
- **No Sandbox** — Unix Domain Socket requires filesystem access outside container
- **No App Store** — direct binary distribution
- **Single instance** — socket connectivity test as implicit lock
- **Apple Silicon + Intel** — universal binary via `swift build`
- **Production = .app bundle** — bare binary is development-only, no notification support

## Non-Goals (v1)

- Custom notification actions (buttons)
- Notification history / log viewer
- Multiple notification categories
- Rich media in notifications (images)
- Network-based IPC (TCP)
- GUI preferences window

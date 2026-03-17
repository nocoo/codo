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
codo              ← no stdin, no args → launches menubar app (daemon mode)
echo '{}' | codo  ← stdin detected    → CLI mode: send to socket, exit
codo --help       ← flag              → print usage, exit
codo --version    ← flag              → print version, exit
```

**Why single binary?** Simpler installation (one file to copy), shared types between CLI and daemon, no version mismatch risk.

### Detection Logic (CLI vs Daemon)

```swift
// Pseudocode
if hasFlag("--help") || hasFlag("--version") {
    // utility mode
} else if !isatty(STDIN_FILENO) || hasStdinData() {
    // CLI mode: read JSON from stdin, send to socket, exit
} else {
    // daemon mode: launch NSApplication menubar app
}
```

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
- Right-click menu: About / Quit
- Own the `SocketServer` instance

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

### 2. Socket Server (`SocketServer`)

Responsibilities:
- Create and listen on Unix Domain Socket at `~/.codo/codo.sock`
- Accept connections, read JSON message, close connection
- Decode `CodoMessage` and forward to `NotificationService`
- Handle socket cleanup on app exit (delete stale `.sock` file)

**Socket path**: `~/.codo/codo.sock`
- `~/.codo/` directory created on first launch if missing
- Stale socket file removed on startup (guard: check if another instance is running via `flock` or PID file)

**Protocol**: newline-delimited JSON, one message per connection.

```
Client connects → sends JSON + newline → server reads → server closes connection
```

### 3. CLI Client (`CLIClient`)

Responsibilities:
- Read JSON from stdin
- Validate message structure
- Connect to Unix Domain Socket
- Send message, wait for ack, exit with appropriate code

**Exit codes**:
| Code | Meaning |
|------|---------|
| 0 | Message delivered |
| 1 | Invalid JSON / missing required fields |
| 2 | Socket not found (daemon not running) |
| 3 | Connection refused / send failed |

### 4. Notification Service (`NotificationService`)

Responsibilities:
- Request notification permission on first use
- Map `CodoMessage` to `UNNotificationContent`
- Post via `UNUserNotificationCenter`

> **CRITICAL GOTCHA** (from Owl): `UNUserNotificationCenter.current()` crashes with `NSInternalInconsistencyException` when `Bundle.main.bundleIdentifier` is nil. This happens in SPM debug builds (`swift run`). **All UNUserNotificationCenter calls MUST guard `bundleIdentifier != nil`**, falling back to `NSLog` in dev mode.

```swift
enum NotificationService {
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }
}
```

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

**SF Symbol: `bell.badge`** (or `bell` when idle)

- `isTemplate = true` — macOS auto-adapts to light/dark menu bar
- Return raw SF Symbol directly, never draw into custom `NSImage` canvas for template icons (Owl lesson)
- Never use `button.contentTintColor` — it also tints `button.title` text (Owl lesson)

### Icon States (future consideration)

| State | Icon | Template |
|-------|------|----------|
| Idle (daemon running) | `bell` | true |
| Recent notification | `bell.badge` | true |

Badge state auto-clears after 5 seconds.

## App Lifecycle

### Launch

1. Detect mode (CLI vs daemon)
2. If daemon:
   a. Check for existing instance (socket file + connectivity test)
   b. If already running → print message, exit
   c. Create `~/.codo/` directory
   d. Start `SocketServer`
   e. Launch `NSApplication` with `.accessory` policy
   f. Request notification permission

### Shutdown

1. `NSApplication.terminate` / SIGTERM / SIGINT
2. Close socket server (stop accepting)
3. Remove socket file (`~/.codo/codo.sock`)
4. Exit

### Launch at Login

- `SMAppService.mainApp` (macOS 13+, from both Owl and Gecko)
- Toggle via right-click menu
- Requires `.app` bundle (not bare binary) — relevant for install process

### Installation

Manual process (v1):

```bash
swift build -c release
# Copy binary to PATH
cp .build/release/Codo /usr/local/bin/codo
```

For daemon mode with `SMAppService` + `UNUserNotificationCenter`, the binary must run inside a `.app` bundle. A `build.sh` script (similar to Owl's) will:

1. `swift build -c release`
2. Assemble `.app` bundle structure (`Contents/MacOS/`, `Contents/Resources/`, `Info.plist`)
3. Copy binary
4. `codesign --force --options runtime` with stable identity

```bash
./scripts/build.sh
cp -r .build/Codo.app /Applications/Codo.app
# CLI: symlink the binary
ln -sf /Applications/Codo.app/Contents/MacOS/Codo /usr/local/bin/codo
```

> **GOTCHA** (from Gecko): Ad-hoc signing (`-`) causes TCC permission loss on every rebuild. Always use stable `Apple Development` identity.

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Build system | SPM only | Owl pattern, `swift build` workflow, no Xcode dependency |
| App entry | Manual `NSApplication` | More control than `MenuBarExtra`, no SwiftUI views needed |
| Single binary | CLI + daemon in one | Simple install, shared types, no version mismatch |
| IPC | Unix Domain Socket | Low latency, local isolation, supports structured messages |
| Message format | stdin JSON | Flexible for hook scripts, no argument parsing complexity |
| Notification | UNUserNotificationCenter | Native macOS toast, respects Do Not Disturb |
| Icon | SF Symbol `bell` | No design asset needed, auto light/dark adaptation |
| Login item | SMAppService | macOS 13+ native, no helper app needed |

## Constraints & Assumptions

- **macOS 14+** (Sonoma) — aligns with Owl's target, modern Swift concurrency
- **No Sandbox** — Unix Domain Socket requires filesystem access outside container
- **No App Store** — direct binary distribution
- **Single instance** — socket file acts as implicit lock
- **Apple Silicon + Intel** — universal binary via `swift build`

## Non-Goals (v1)

- Custom notification actions (buttons)
- Notification history / log viewer
- Multiple notification categories
- Rich media in notifications (images)
- Network-based IPC (TCP)
- GUI preferences window

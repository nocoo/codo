# 05 — Dashboard: Professional Multi-Panel App

## Overview

将 Codo 从纯 Settings 弹窗升级为专业三栏 Dashboard 应用。

**目标**：左侧导航 + 中间内容区 + 暗色主题。窗口打开时临时显示 Dock 图标（Hybrid 模式）。项目从 hook event 的 `cwd` 字段自动发现。

**技术栈**：AppKit 做窗口壳（NSWindow + NSSplitViewController），SwiftUI 做所有内容面板（通过 NSHostingView 嵌入）。

---

## Architecture

```
MainWindowController (NSWindowController + NSWindowDelegate)
└─ NSWindow (1000×700, titled+closable+resizable+miniaturizable)
   └─ NSSplitViewController
      ├─ Sidebar (220pt, NSHostingView<SidebarView>)
      │  ├─ Nav: Dashboard / Settings / Logs
      │  └─ Projects: auto-discovered from hook events
      └─ Detail (flex, NSHostingView<DetailContainerView>)
         ├─ DashboardView
         │  ├─ GuardianStatusCard
         │  ├─ StatsCard (sent / suppressed / sessions)
         │  ├─ ActiveSessionsList
         │  └─ LiveEventStream
         ├─ SettingsView (migrated from SettingsWindow.swift)
         └─ LogsView (tail guardian.log + hooks.log)
```

### Hybrid Dock Mode

- Default: menubar-only (`NSApp.setActivationPolicy(.accessory)`)
- Window opens → `NSApp.setActivationPolicy(.regular)` (Dock icon appears)
- Window closes → `NSApp.setActivationPolicy(.accessory)` (Dock icon hides)
- Pattern: Bartender / Raycast

---

## Data Flow

### Current: Dumb Pipe

```
SocketServer → MessageRouter → AppDelegate.dispatchHookEvent(rawJSON:)
                                 ├─ Guardian alive → guardian.send(rawJSON)
                                 └─ Guardian dead  → deliverFallback(rawJSON)
```

Swift 层不解析 hook event JSON — 原始 bytes 直接转发到 Guardian stdin。

### New: Tap for Dashboard

```
AppDelegate.dispatchHookEvent(rawJSON:)
  ├─ [NEW] decode rawJSON → HookEvent → DashboardStore.ingestHookEvent()
  ├─ Guardian alive → guardian.send(rawJSON)      (unchanged)
  └─ Guardian dead  → deliverFallback(rawJSON)    (unchanged)

GuardianProcess.readStdoutLoop() → GuardianAction
  ├─ [NEW] onAction callback → DashboardStore.ingestGuardianAction()
  ├─ action == "send" → notificationService.post()  (unchanged)
  └─ action == "suppress" → no-op                   (unchanged)
```

`cwd` 字段在所有 hook event 中可用（`session-start`, `stop`, `post-tool-use` 等）。已被 Guardian TypeScript 层用于 session 追踪（`guardian/state.ts`）。

---

## Implementation Phases

### Phase 1: Data Layer

#### 1a. `Sources/CodoCore/HookEvent.swift` — NEW

Lightweight decode of hook JSON（只取需要的字段，`init(from:)` 不会因多余字段报错）：

```swift
public struct HookEvent: Decodable, Sendable {
    public let hook: String          // "_hook"
    public let sessionId: String?    // "session_id"
    public let cwd: String?
    public let model: String?
    public let hookEventName: String? // "hook_event_name"
}
```

#### 1b. `Sources/Codo/Dashboard/Models/` — NEW

| File | Type | Key Fields |
|------|------|------------|
| `NavigationItem.swift` | `enum` | `dashboard`, `settings`, `logs` + SF Symbol + label |
| `EventEntry.swift` | `struct Identifiable` | `id: UUID`, `timestamp`, `hookType`, `projectName?`, `summary`, `action?` |
| `SessionInfo.swift` | `struct Identifiable` | `id: String` (sessionId), `cwd`, `projectName`, `model?`, `startTime` |
| `ProjectInfo.swift` | `struct Identifiable, Codable` | `id: String` (cwd path), `name`, `customLogoPath?`, `lastSeen` |

#### 1c. `Sources/Codo/Dashboard/DashboardStore.swift` — NEW

`@Observable` class (macOS 14+ Observation framework)。Single source of truth。

**Properties:**

| Property | Type | Source |
|----------|------|--------|
| `guardianAlive` | `Bool` | Polled from `GuardianProcess.isAlive` every 2s |
| `socketAlive` | `Bool` | Polled from `SocketServer` running state |
| `guardianUptime` | `TimeInterval` | Tracked from process start |
| `notificationsSent` | `Int` | Incremented from `GuardianAction(action: "send")` |
| `notificationsSuppressed` | `Int` | Incremented from `GuardianAction(action: "suppress")` |
| `events` | `[EventEntry]` | Ring buffer max 200, newest first |
| `activeSessions` | `[SessionInfo]` | Keyed by sessionId |
| `projects` | `[ProjectInfo]` | Auto-discovered from cwd, persisted to UserDefaults |

**Methods:**

| Method | Trigger |
|--------|---------|
| `ingestHookEvent(_ event: HookEvent)` | AppDelegate tap on dispatchHookEvent |
| `ingestGuardianAction(_ action: GuardianAction)` | GuardianProcess.onAction callback |
| `startPolling(guardian:socketServer:)` | Called once from AppDelegate after daemon starts |

#### 1d. `Sources/CodoCore/GuardianProcess.swift` — MODIFY (~5 lines)

```swift
// New property
public var onAction: ((GuardianAction) -> Void)?

// In readStdoutLoop(), after successful decode of action:
DispatchQueue.main.async { [weak self] in
    self?.onAction?(action)
}
```

#### 1e. `Sources/Codo/AppDelegate.swift` — MODIFY (~30 lines changed)

- Add `private let dashboardStore = DashboardStore()`
- In `dispatchHookEvent(rawJSON:)`: decode → `HookEvent`, call `dashboardStore.ingestHookEvent()`
- In `spawnGuardianIfNeeded()`: connect `proc.onAction = { dashboardStore.ingestGuardianAction($0) }`
- After `startDaemon()`: call `dashboardStore.startPolling(guardian:socketServer:)`
- Replace `settingsWindow: SettingsWindowController?` → `mainWindow: MainWindowController?`
- Replace `openSettings()` → `openDashboard()`
- Menu item: "Settings..." Cmd+, → "Dashboard..." Cmd+D

**Atomic commit**: Phase 1 result = 编译通过，数据层就绪，无 UI 变化。

---

### Phase 2: Window Shell

#### 2a. `Sources/Codo/Dashboard/MainWindowController.swift` — NEW

| Config | Value |
|--------|-------|
| Size | 1000×700 default, 800×500 minimum |
| Style | `.titled, .closable, .resizable, .miniaturizable` |
| Titlebar | `titlebarAppearsTransparent = true`, `titleVisibility = .hidden` |
| Background | `.windowBackgroundColor` (auto dark mode) |
| Persistence | `isReleasedWhenClosed = false`, `setFrameAutosaveName("CodoDashboard")` |

Content: `NSSplitViewController` with 2 items:
- **Sidebar**: `NSSplitViewItem.sidebarWithViewController(vc)` — 220pt preferred, 180pt min, not collapsible. VC view = `NSHostingView<SidebarView>`.
- **Detail**: `NSSplitViewItem.contentList(with: vc)` — flexible. VC view = `NSHostingView<DetailContainerView>`.

Hybrid Dock toggle in `showWindow()` / `windowWillClose(_:)`.

Pass `DashboardStore` + `SettingsViewModel` into SwiftUI via `.environment()`.

#### 2b. `Sources/Codo/Dashboard/Views/SidebarView.swift` — NEW

SwiftUI View with vibrancy background.

- Section "NAVIGATION": `NavigationItem` list with SF Symbols
  - `gauge.open.with.lines.needle.33percent` → Dashboard
  - `gearshape` → Settings
  - `doc.text` → Logs
- Divider
- Section "PROJECTS": ForEach `DashboardStore.projects`
  - Logo (custom or default folder icon) + name + last-seen relative time
  - Click → highlight project in ActiveSessions
  - Context menu / button → set custom logo (NSOpenPanel / `fileImporter`)

#### 2c. `Sources/Codo/Dashboard/Views/DetailContainerView.swift` — NEW

Switch on `selectedNav`:
```swift
switch selectedNav {
case .dashboard: DashboardView()
case .settings:  SettingsView()
case .logs:      LogsView()
}
```

**Atomic commit**: Phase 2 result = 三栏窗口骨架可显示，sidebar 导航可切换，detail 区域有 placeholder。

---

### Phase 3: Dashboard Cards

#### 3a. `Sources/Codo/Dashboard/Views/CardView.swift` — NEW

Reusable card wrapper: rounded corner (12pt), subtle border, dark fill. Accepts `title: String` + `@ViewBuilder content`.

#### 3b. `Sources/Codo/Dashboard/Views/DashboardView.swift` — NEW

Layout (VStack):
1. **Top row** (HStack): `GuardianStatusCard` + `StatsCard`
2. **Middle**: `ActiveSessionsList`
3. **Bottom** (flex): `LiveEventStream`

#### 3c. `Sources/Codo/Dashboard/Views/GuardianStatusCard.swift` — NEW

- Green/red dot + "Guardian Running" / "Guardian Stopped"
- Socket status indicator
- Uptime display (formatted as HH:mm:ss)

#### 3d. `Sources/Codo/Dashboard/Views/StatsCard.swift` — NEW

Three stat numbers: Sent / Suppressed / Active Sessions. Today's counts.

#### 3e. `Sources/Codo/Dashboard/Views/ActiveSessionsList.swift` — NEW

- Each session row: project name (basename of cwd) + model badge + duration
- Green pulsing dot for active
- Empty state: "No active sessions"

#### 3f. `Sources/Codo/Dashboard/Views/LiveEventStream.swift` — NEW

- `ScrollViewReader` + `LazyVStack` from `DashboardStore.events`
- Each event: timestamp + hook type badge (color-coded) + project name + summary
- Auto-scroll to newest event
- Conversation-flow style (inspired by the reference screenshot)

**Atomic commit**: Phase 3 result = Dashboard 页面完整可用，实时数据展示。

---

### Phase 4: Settings Migration

#### 4a. `Sources/Codo/Dashboard/Views/SettingsView.swift` — NEW

SwiftUI Form wrapping existing `SettingsViewModel` (`@StateObject`).

Fields (identical to current):

| Field | SwiftUI Control | Visibility |
|-------|----------------|------------|
| AI Guardian | `Toggle` | Always |
| Provider | `Picker` (Anthropic, MiniMax, GLM, AIHubMix, Custom) | Always |
| API Key | `SecureField` | Always |
| Base URL | `TextField` | Custom provider only |
| Model | `Picker` (dynamic per provider) | Always |
| SDK Type | `Picker` (OpenAI / Anthropic) | Custom provider only |
| Context Limit | `TextField` (numeric) | Always |
| Save / Cancel | `Button` pair | Always |

Save → `viewModel.save()` + post `settingsDidSave` notification (reuse existing flow).

#### 4b. Delete `Sources/Codo/SettingsWindow.swift`

Move `SettingsWindowController.settingsDidSave` notification name constant to `SettingsViewModel`.

**Atomic commit**: Phase 4 result = Settings 功能完全迁移到 SwiftUI，旧 AppKit 设置窗口删除。

---

### Phase 5: Logs + Projects

#### 5a. `Sources/Codo/Dashboard/Views/LogsView.swift` — NEW

- Tab picker: `guardian.log` / `hooks.log`
- File monitoring: `DispatchSource.makeFileSystemObjectSource(.write)` on file descriptor
- Read: `FileHandle.seekToEndOfFile()` - N bytes, display latest lines
- Monospace font, dark background
- Auto-scroll on new content

#### 5b. `Sources/Codo/Dashboard/Views/ProjectRow.swift` — NEW

Project row for sidebar: logo image (64×64) + name + relative time badge.

#### 5c. Project Logo Storage

- Path: `~/.codo/project-logos/<sanitized-name>.png`
- Picker: `fileImporter(isPresented:allowedContentTypes:)` in SwiftUI
- Save: resize to 64×64 PNG
- Model: `ProjectInfo.customLogoPath` stores path

**Atomic commit**: Phase 5 result = Logs 实时查看 + 项目 logo 自定义。

---

### Phase 6: Polish

- Window frame autosave (`setFrameAutosaveName`)
- Keyboard shortcuts: Cmd+1/2/3 nav switch
- Dark theme enforcement or system-following
- Animations: sidebar selection, card appear, event stream scroll
- Empty states with placeholder illustrations
- Status bar icon animation when Guardian is processing

**Atomic commit**: Phase 6 result = 视觉打磨，交互细节完善。

---

## File Inventory

### New Files (18)

| # | File | ~Lines |
|---|------|--------|
| 1 | `Sources/CodoCore/HookEvent.swift` | ~20 |
| 2 | `Sources/Codo/Dashboard/Models/NavigationItem.swift` | ~20 |
| 3 | `Sources/Codo/Dashboard/Models/EventEntry.swift` | ~15 |
| 4 | `Sources/Codo/Dashboard/Models/SessionInfo.swift` | ~15 |
| 5 | `Sources/Codo/Dashboard/Models/ProjectInfo.swift` | ~20 |
| 6 | `Sources/Codo/Dashboard/DashboardStore.swift` | ~150 |
| 7 | `Sources/Codo/Dashboard/MainWindowController.swift` | ~130 |
| 8 | `Sources/Codo/Dashboard/Views/SidebarView.swift` | ~120 |
| 9 | `Sources/Codo/Dashboard/Views/DetailContainerView.swift` | ~30 |
| 10 | `Sources/Codo/Dashboard/Views/DashboardView.swift` | ~80 |
| 11 | `Sources/Codo/Dashboard/Views/CardView.swift` | ~30 |
| 12 | `Sources/Codo/Dashboard/Views/GuardianStatusCard.swift` | ~60 |
| 13 | `Sources/Codo/Dashboard/Views/StatsCard.swift` | ~50 |
| 14 | `Sources/Codo/Dashboard/Views/ActiveSessionsList.swift` | ~70 |
| 15 | `Sources/Codo/Dashboard/Views/LiveEventStream.swift` | ~90 |
| 16 | `Sources/Codo/Dashboard/Views/SettingsView.swift` | ~200 |
| 17 | `Sources/Codo/Dashboard/Views/LogsView.swift` | ~120 |
| 18 | `Sources/Codo/Dashboard/Views/ProjectRow.swift` | ~50 |

### Modified Files (3)

| File | Changes |
|------|---------|
| `Sources/CodoCore/GuardianProcess.swift` | Add `onAction` callback (~5 lines) |
| `Sources/Codo/AppDelegate.swift` | Replace settings window → main window, add DashboardStore wiring, hook event tap, menu item change (~30 lines) |
| `Sources/Codo/SettingsViewModel.swift` | Move `settingsDidSave` notification name here |

### Deleted Files (1)

| File | Reason |
|------|--------|
| `Sources/Codo/SettingsWindow.swift` | Replaced by SwiftUI `SettingsView` |

### SPM Note

No `Package.swift` changes needed — SPM auto-includes all `.swift` files under `Sources/Codo/` subdirectories. SwiftUI is a system framework, no dependency required.

---

## Verification

```bash
# Build
./scripts/build.sh

# Restart
pkill -f "Codo.app/Contents/MacOS/Codo" 2>/dev/null; sleep 1
open .build/release/Codo.app

# 1. Dashboard opens via menubar → "Dashboard..." (Cmd+D)
#    → Three-panel layout, Dock icon appears

# 2. Live event flow
echo '{"title":"Test","body":"Hello","source":"codo"}' | bun ~/.codo/codo.ts
#    → Event appears in LiveEventStream

# 3. Session tracking
#    Start Claude Code session → session-start hook fires
#    → Project auto-discovered in sidebar, session in ActiveSessionsList

# 4. Settings
#    Navigate to Settings, change provider, save
#    → Guardian restarts with new config

# 5. Hybrid Dock mode
#    Close dashboard → Dock icon disappears
#    Reopen → Dock icon reappears

# 6. All tests pass
swift test && bun test && cd cli && bun test
```

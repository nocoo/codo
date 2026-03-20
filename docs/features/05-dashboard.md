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

`cwd` 字段在大多数 hook event 中可用（`session-start`, `stop`, `post-tool-use` 等），但 **`session-end` 可能没有 `cwd` 字段**。因此 `HookEvent.cwd` 必须是 `String?`。处理 `session-end` 时需通过 `session_id` 查找对应的已知 session 来获取 cwd/项目信息，不能假设 `cwd` 一定存在。

---

## Implementation Phases

### Phase 1: Data Layer

#### 1a. `Sources/CodoCore/HookEvent.swift` — NEW

Lightweight decode of hook JSON。**必须使用显式 CodingKeys**，因为实际 payload 的 key 是 `_hook`、`session_id`、`hook_event_name`（下划线前缀 + snake_case），`keyDecodingStrategy = .convertFromSnakeCase` 无法正确处理 `_hook`（会转为 `Hook` 而非 `hook`）。

```swift
public struct HookEvent: Decodable, Sendable {
    public let hook: String
    public let sessionId: String?
    public let cwd: String?
    public let model: String?
    public let hookEventName: String?

    private enum CodingKeys: String, CodingKey {
        case hook = "_hook"
        case sessionId = "session_id"
        case cwd
        case model
        case hookEventName = "hook_event_name"
    }
}
```

Decoder 必须使用默认 `keyDecodingStrategy`（不设 `.convertFromSnakeCase`），依赖 CodingKeys 做精确映射。多余字段会被自动忽略（Decodable 默认行为）。

**测试覆盖**：`Tests/CodoCoreTests/HookEventTests.swift` — 用实际 payload fixture 验证 decode 正确性（包括 `_hook` 前缀、`session_id` snake_case、缺失可选字段的情况）。

#### 1b. `Sources/Codo/Dashboard/Models/` — NEW

| File | Type | Key Fields |
|------|------|------------|
| `NavigationItem.swift` | `enum` | `dashboard`, `settings`, `logs` + SF Symbol + label |
| `EventEntry.swift` | `struct Identifiable` | `id: UUID`, `timestamp`, `hookType`, `projectName?`, `summary`, `action?` |
| `SessionInfo.swift` | `struct Identifiable` | `id: String` (sessionId), `cwd`, `projectName`, `model?`, `startTime` |
| `ProjectInfo.swift` | `struct Identifiable, Codable` | `id: String` (cwd path), `name`, `customLogoPath?`, `lastSeen` |

#### 1c. `Sources/Codo/Dashboard/DashboardStore.swift` — NEW

`@MainActor @Observable` class (macOS 14+ Observation framework)。Single source of truth。**必须标记 `@MainActor`**，因为 `@Observable` 的属性变更必须发生在主线程才能安全驱动 SwiftUI 更新。

**Properties:**

| Property | Type | Source |
|----------|------|--------|
| `guardianAlive` | `Bool` | Polled from `GuardianProcess.isAlive` every 2s |
| `socketAlive` | `Bool` | Polled from `SocketServer.isListening` (新增 public computed property，见 Phase 1d2) |
| `guardianUptime` | `TimeInterval` | Tracked from process start |
| `notificationsSent` | `Int` | Incremented from `GuardianAction(action: "send")` |
| `notificationsSuppressed` | `Int` | Incremented from `GuardianAction(action: "suppress")` |
| `events` | `[EventEntry]` | Ring buffer max 200, newest first |
| `activeSessions` | `[SessionInfo]` | Keyed by sessionId |
| `projects` | `[ProjectInfo]` | Auto-discovered from cwd, persisted to UserDefaults |

**Methods:**

| Method | Trigger |
|--------|---------|
| `ingestHookEvent(_ event: HookEvent)` | AppDelegate tap on dispatchHookEvent. 对于 `session-end`（可能没有 `cwd`），通过 `event.sessionId` 在 `activeSessions` 中查找对应 session 来获取 `cwd`/项目信息 |
| `ingestGuardianAction(_ action: GuardianAction)` | GuardianProcess.onAction callback |
| `startPolling(guardianProvider:socketServer:)` | Called once from AppDelegate after daemon starts |

**Guardian 引用策略**：`startPolling` 接受的 `guardianProvider` 参数类型为 `() -> GuardianProvider?`（closure，不是直接引用）。因为 `AppDelegate` 会在 `settingsDidSave` 时 stop 旧 guardian 再 spawn 新 guardian，直接持有实例引用会指向已 stop 的旧进程。改为 closure 让每次 poll 都从 `AppDelegate.guardian` 取最新实例：

```swift
func startPolling(
    guardianProvider: @escaping () -> GuardianProvider?,
    socketServer: SocketServer?
) {
    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
        guard let self else { return }
        self.guardianAlive = guardianProvider()?.isAlive ?? false
        self.socketAlive = socketServer?.isListening ?? false
        // ...
    }
}
```

AppDelegate 调用时：
```swift
dashboardStore.startPolling(
    guardianProvider: { [weak self] in self?.guardian },
    socketServer: socketServer
)
```

#### 1d. `Sources/CodoCore/GuardianProcess.swift` — MODIFY (~5 lines)

```swift
// New property — nonisolated closure, 由调用方负责线程安全
public var onAction: (@Sendable (GuardianAction) -> Void)?

// In readStdoutLoop(), after successful decode of action:
// 注意：直接在 stdout reader 线程回调，不做 main thread hop
// 调用方（AppDelegate）在赋值闭包内自行 hop 到 @MainActor
self?.onAction?(action)
```

`onAction` 标记 `@Sendable` 而非 `@MainActor`，因为 `GuardianProcess` 属于 `CodoCore` 底层模块，不应感知上层的 actor 隔离策略。线程跳转责任在调用方。

#### 1d2. `Sources/CodoCore/SocketServer.swift` — MODIFY (~1 line)

当前 `running` 是 `private nonisolated(unsafe) var`，外部无法访问。需添加 public computed property：

```swift
/// Whether the server is currently listening for connections.
public var isListening: Bool { running }
```

添加在 `public static let maxPayloadSize` 上方。

#### 1e. `Sources/Codo/AppDelegate.swift` — MODIFY (~30 lines changed)

- Add `private let dashboardStore = DashboardStore()`
- In `dispatchHookEvent(rawJSON:)`: decode → `HookEvent`, then **必须 hop 到 main thread** 再调用 `dashboardStore.ingestHookEvent()`。原因：`dispatchHookEvent` 由 `SocketServer` 的 GCD handler 调用（`DispatchQueue.global(qos: .userInitiated)`），而 `DashboardStore` 标记为 `@MainActor`，从非主线程直接调用会触发 data race / Swift 并发警告。实现方式：
  ```swift
  func dispatchHookEvent(rawJSON: Data) {
      // ... existing guardian/fallback logic ...

      // NEW: tap for dashboard (non-blocking main-thread hop)
      if let event = try? JSONDecoder().decode(HookEvent.self, from: rawJSON) {
          Task { @MainActor in
              dashboardStore.ingestHookEvent(event)
          }
      }
  }
  ```
- In `spawnGuardianIfNeeded()`: connect onAction — **必须在闭包内 hop 到 `@MainActor`**，因为 `onAction` 是 `@Sendable` nonisolated 闭包，从 stdout reader 线程回调，不能直接调用 `@MainActor` 的 `dashboardStore`：
  ```swift
  proc.onAction = { [weak self] action in
      Task { @MainActor in
          self?.dashboardStore.ingestGuardianAction(action)
      }
  }
  ```
- After `startDaemon()`: call `dashboardStore.startPolling(guardianProvider: { [weak self] in self?.guardian }, socketServer: socketServer)`
- Replace `settingsWindow: SettingsWindowController?` → `mainWindow: MainWindowController?`
- Replace `openSettings()` → `openDashboard()`
- Menu item: "Settings..." Cmd+, → "Dashboard..." Cmd+D

**Atomic commit**: Phase 1 result = 编译通过，数据层就绪，无 UI 变化。

**线程安全总结**：`DashboardStore` 标记 `@MainActor`，所有写入入口必须在主线程：
- `startPolling` Timer — `Timer.scheduledTimer` 默认在 main RunLoop 触发 ✅
- `ingestHookEvent()` — 由 `dispatchHookEvent` 通过 `Task { @MainActor in }` 跳转 ✅
- `ingestGuardianAction()` — 由 `onAction` 闭包内部 `Task { @MainActor in }` 跳转 ✅（`GuardianProcess` 不做 hop，调用方负责）

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

Pass `DashboardStore` via `.environment()` (Observation framework) and `SettingsViewModel` via `.environmentObject()` (Combine `ObservableObject`) into SwiftUI root views。**`SettingsViewModel` 全局仅一个实例**，由 `MainWindowController` 持有：

```swift
// MainWindowController
private let settingsViewModel = SettingsViewModel()

// 构建 NSHostingView 时:
let sidebarView = SidebarView(...)
    .environmentObject(settingsViewModel)
    .environment(dashboardStore)

let detailView = DetailContainerView(...)
    .environmentObject(settingsViewModel)
    .environment(dashboardStore)
```

注意两种注入方式的区别：
- `DashboardStore` 是 `@Observable`（macOS 14+ Observation）→ 用 `.environment()`
- `SettingsViewModel` 是 `ObservableObject`（Combine）→ 用 `.environmentObject()`

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

SwiftUI Form，通过 `@EnvironmentObject var viewModel: SettingsViewModel` 获取实例（由 `MainWindowController` 在 Phase 2a 注入，全局唯一实例）。**不使用 `@StateObject`**，避免创建重复实例导致状态不同步。

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

- Path: `~/.codo/project-logos/<sha256-of-cwd-prefix-8>.png`
  - 用 cwd 绝对路径的 SHA256 前 8 位作为文件名，而不是 basename
  - 原因：两个不同路径但 basename 相同的项目（如 `/work/app` 和 `/personal/app`）必须有独立 logo
  - `ProjectInfo.id` 是 cwd path，logo 文件名也基于 cwd path 派生，保持键一致
- Picker: `fileImporter(isPresented:allowedContentTypes:)` in SwiftUI
- Save: resize to 64×64 PNG
- Model: `ProjectInfo.customLogoPath` stores full path to logo file

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

### Modified Files (4)

| File | Changes |
|------|---------|
| `Sources/CodoCore/GuardianProcess.swift` | Add `onAction` callback (~5 lines) |
| `Sources/CodoCore/SocketServer.swift` | Add `public var isListening: Bool { running }` (~1 line) |
| `Sources/Codo/AppDelegate.swift` | Replace settings window → main window, add DashboardStore wiring, hook event tap with `Task { @MainActor in }` hop, menu item change (~30 lines) |
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

# 2. Live event flow — test with a HOOK event (not plain notification)
#    Plain notification (echo '{"title":...}') goes through notification path,
#    NOT through dispatchHookEvent, so it won't appear in LiveEventStream.
#    IMPORTANT: CLI requires `--hook <type>` to enter hook mode.
#    Without --hook, stdin is parsed as a notification and will fail on missing title.
echo '{"session_id":"test-123","cwd":"/tmp/test-project","hook_event_name":"Stop","last_assistant_message":"All done"}' | bun ~/.codo/codo.ts --hook stop
#    → Event appears in LiveEventStream with project "test-project"
#    → If Guardian is alive, Guardian will also process and may send a notification

# 2b. Direct notification path (verifies banner still works, NOT event stream)
echo '{"title":"Banner Test","body":"This is a direct notification","source":"codo"}' | bun ~/.codo/codo.ts
#    → Banner notification appears (this does NOT feed into LiveEventStream)

# 3. Session tracking
echo '{"session_id":"s-abc","cwd":"/Users/nocoo/workspace/personal/codo","model":"claude-sonnet-4-6","hook_event_name":"SessionStart"}' | bun ~/.codo/codo.ts --hook session-start
#    → Project "codo" auto-discovered in sidebar, session in ActiveSessionsList
echo '{"session_id":"s-abc","hook_event_name":"SessionEnd"}' | bun ~/.codo/codo.ts --hook session-end
#    → Session removed from ActiveSessionsList (note: session-end may lack cwd)

# 4. Settings
#    Navigate to Settings, change provider, save
#    → Guardian restarts with new config

# 5. Hybrid Dock mode
#    Close dashboard → Dock icon disappears
#    Reopen → Dock icon reappears

# 6. All tests pass
swift test && bun test && cd cli && bun test
```

### Data Path Clarification

Two distinct paths exist and must be tested separately:

| Path | Trigger | Dashboard Effect |
|------|---------|-----------------|
| **Hook event** | JSON with `_hook` field → `MessageRouter.hookEvent` → `dispatchHookEvent` | ✅ Feeds into `DashboardStore.ingestHookEvent()` → LiveEventStream, Sessions, Projects |
| **Direct notification** | JSON without `_hook` (has `title`) → `MessageRouter.notification` → `notificationService.post()` | ❌ Does NOT feed into DashboardStore — goes straight to banner |

# 08 — Dashboard & Log Unification

## Problem Statement

Dashboard 和 Guardian 日志系统之间存在**数据断裂**，导致 Dashboard 无法完整展示运行情况和历史记录。

### 现状问题一览

| # | 问题 | 影响 |
|---|------|------|
| 1 | Dashboard 事件/统计纯内存，app 重启归零 | 无法查看历史运行数据 |
| 2 | guardian.log 无轮转，无限增长（当前 3.3MB） | 磁盘浪费，LogsView 只读尾部 32KB 无法回溯 |
| 3 | Guardian (TS) 和 DashboardStore (Swift) 两套独立状态 | 数据不一致，LLM token 用量等高价值数据只存在 guardian.log 文本中 |
| 4 | 通知历史不持久化 | StateStore 内存 ring buffer 200 条，重启丢失 |
| 5 | LogsView 是原始文本尾读，无结构化筛选 | 无法按项目/时间/类型过滤日志 |
| 6 | 直接通知（无 `_hook` 字段）不进入 DashboardStore | 通过 `echo '{"title":...}' \| bun codo.ts` 发送的通知在 Dashboard 不可见 |
| 7 | LLM 调用成本/token 用量无结构化追踪 | 只能 grep guardian.log 事后挖掘 |

### 数据流断裂图

```
┌─────────────────────────────────────────────────────────────────┐
│                      当前数据流                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Claude Code hooks                                              │
│       │                                                         │
│       ▼                                                         │
│  claude-hook.sh ──► codo CLI ──► Unix Socket ──► Codo.app       │
│                                                    │            │
│                              ┌─────────────────────┤            │
│                              │                     │            │
│                              ▼                     ▼            │
│                     dispatchHookEvent        MessageRouter      │
│                     (有 _hook 字段)        (无 _hook = 直接通知) │
│                       │      │                     │            │
│                       │      ▼                     ▼            │
│                       │   DashboardStore    NotificationService  │
│                       │   (内存 ring buf)   (直接发送，不记录)   │  ◄── 断裂点❶
│                       │                                         │
│                       ▼                                         │
│                   Guardian (TS)                                  │
│                   ├─ StateStore (内存，独立于 Swift 侧)          │  ◄── 断裂点❷
│                   ├─ stderr → guardian.log (纯文本，无轮转)      │  ◄── 断裂点❸
│                   └─ stdout → GuardianAction → DashboardStore   │
│                                (仅 send/suppress 计数)          │  ◄── 断裂点❹
│                                                                 │
│  断裂点❶: 直接通知绕过 DashboardStore                            │
│  断裂点❷: TS/Swift 两套状态各管各的                              │
│  断裂点❸: guardian.log 是唯一的"持久层"但是纯文本                 │
│  断裂点❹: Guardian 决策的丰富信息(tier/reason/tokens)不回传       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Design Goals

1. **Dashboard 能完整看到运行情况** — 包括直接通知、Guardian 决策详情、LLM token 用量
2. **历史 log 分项目** — 按 project (cwd) 筛选事件，可回溯数天
3. **App 重启不丢数据** — 事件、统计、通知历史持久化
4. **guardian.log 可控** — 轮转 + 结构化存储双轨并行
5. **最小侵入** — 复用现有 IPC 管道，不引入新外部依赖

---

## Architecture

### 新增持久层：SQLite

引入 SQLite 作为唯一结构化持久存储（替代 UserDefaults + 纯文本日志的拼凑方案）。

**理由**：
- macOS 原生支持（`import SQLite3`），零外部依赖
- 支持按项目、时间、类型的高效查询
- 单文件，备份/迁移简单
- WAL 模式支持读写并发

**存储位置**：`~/.codo/codo.db`

### 数据库 Schema

```sql
-- 事件表：所有 hook event + 直接通知 + guardian action 统一存储
CREATE TABLE events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp   TEXT    NOT NULL,  -- ISO-8601
    type        TEXT    NOT NULL,  -- 'hook' | 'notification' | 'guardian_action'
    hook_type   TEXT,              -- 'session-start' | 'stop' | 'post-tool-use' | ...
    session_id  TEXT,
    project_cwd TEXT,              -- canonical cwd path
    project_name TEXT,             -- basename of cwd
    summary     TEXT,
    raw_json    TEXT,              -- complete original JSON for replay/debug
    created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_events_project ON events(project_cwd, timestamp);
CREATE INDEX idx_events_type    ON events(type, timestamp);
CREATE INDEX idx_events_session ON events(session_id);

-- Guardian 决策表：每次 LLM 调用的结构化记录
CREATE TABLE guardian_decisions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp       TEXT    NOT NULL,
    session_id      TEXT,
    project_cwd     TEXT,
    hook_type       TEXT,           -- triggering hook
    tier            TEXT,           -- 'important' | 'contextual' | 'noise'
    action          TEXT,           -- 'send' | 'suppress'
    title           TEXT,           -- notification title (if sent)
    reason          TEXT,           -- LLM reasoning
    model           TEXT,           -- LLM model used
    prompt_tokens   INTEGER,
    completion_tokens INTEGER,
    latency_ms      INTEGER,
    created_at      TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_decisions_project ON guardian_decisions(project_cwd, timestamp);

-- 每日统计快照（按项目聚合，用于 Dashboard StatsCard 快速加载）
CREATE TABLE daily_stats (
    date            TEXT    NOT NULL,  -- YYYY-MM-DD
    project_cwd     TEXT    NOT NULL,
    events_count    INTEGER NOT NULL DEFAULT 0,
    sent_count      INTEGER NOT NULL DEFAULT 0,
    suppressed_count INTEGER NOT NULL DEFAULT 0,
    prompt_tokens   INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    llm_calls       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (date, project_cwd)
);

-- 项目表（从 UserDefaults 迁移）
CREATE TABLE projects (
    cwd             TEXT    PRIMARY KEY,
    name            TEXT    NOT NULL,
    custom_logo_path TEXT,
    last_seen       TEXT    NOT NULL,
    created_at      TEXT    NOT NULL DEFAULT (datetime('now'))
);
```

### 改造后的数据流

```
┌─────────────────────────────────────────────────────────────────┐
│                      改造后数据流                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Claude Code hooks                                              │
│       │                                                         │
│       ▼                                                         │
│  claude-hook.sh ──► codo CLI ──► Unix Socket ──► Codo.app       │
│                                                    │            │
│                              ┌─────────────────────┤            │
│                              │                     │            │
│                              ▼                     ▼            │
│                     dispatchHookEvent        MessageRouter      │
│                     (有 _hook 字段)        (无 _hook = 直接通知) │
│                       │      │                     │            │
│                       │      ▼                     ▼            │
│                       │   DashboardStore ◄── [NEW] 直接通知也入库│
│                       │      │                                  │
│                       │      ▼                                  │
│                       │   EventStore (SQLite)  ◄── 持久化       │
│                       │                                         │
│                       ▼                                         │
│                   Guardian (TS)                                  │
│                   ├─ StateStore (内存，不变)                     │
│                   ├─ stderr → guardian.log (保留，加轮转)        │
│                   └─ stdout → GuardianAction                    │
│                               │                                 │
│                               ▼                                 │
│                    [ENHANCED] GuardianAction                     │
│                    {action, title, body,                         │
│                     tier, reason, model,       ◄── 新增字段      │
│                     prompt_tokens, completion_tokens,            │
│                     latency_ms, session_id, cwd}                │
│                               │                                 │
│                               ▼                                 │
│                   DashboardStore.ingestGuardianAction()          │
│                               │                                 │
│                               ▼                                 │
│                   EventStore.insertDecision()  ◄── 持久化       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Implementation Phases

### Phase 1: EventStore — SQLite 持久层

#### 1a. `Sources/CodoCore/EventStore.swift` — NEW

Swift wrapper around SQLite3 C API（不引入第三方 ORM）。

```swift
public final class EventStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.hexly.codo.eventstore")

    public init(path: String = "\(NSHomeDirectory())/.codo/codo.db")
    public func insertEvent(_ event: EventRecord)
    public func insertDecision(_ decision: DecisionRecord)
    public func queryEvents(
        project: String? = nil,
        type: String? = nil,
        since: Date? = nil,
        limit: Int = 200
    ) -> [EventRecord]
    public func queryDecisions(
        project: String? = nil,
        since: Date? = nil,
        limit: Int = 100
    ) -> [DecisionRecord]
    public func dailyStats(
        project: String? = nil,
        days: Int = 7
    ) -> [DailyStatsRecord]
    public func upsertProject(_ project: ProjectRecord)
    public func loadProjects() -> [ProjectRecord]
    public func vacuum(keepDays: Int = 30)  // 清理超过 N 天的旧数据
}
```

关键设计决策：
- **线程安全**：通过串行 `DispatchQueue` 序列化所有 DB 操作
- **WAL 模式**：`PRAGMA journal_mode=WAL` — 支持 Dashboard 读取同时写入
- **自动清理**：`vacuum()` 清除超过 30 天的数据，由 app 启动时调用
- **不用 Core Data**：过重，且 Codo 是 `.accessory` 模式无需 iCloud 同步

#### 1b. Record types (`Sources/CodoCore/EventStoreRecords.swift`) — NEW

```swift
public struct EventRecord: Codable, Sendable {
    public let timestamp: Date
    public let type: String          // "hook" | "notification" | "guardian_action"
    public let hookType: String?
    public let sessionId: String?
    public let projectCwd: String?
    public let projectName: String?
    public let summary: String
    public let rawJson: String?
}

public struct DecisionRecord: Codable, Sendable {
    public let timestamp: Date
    public let sessionId: String?
    public let projectCwd: String?
    public let hookType: String?
    public let tier: String?
    public let action: String        // "send" | "suppress"
    public let title: String?
    public let reason: String?
    public let model: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let latencyMs: Int?
}

public struct DailyStatsRecord: Codable, Sendable {
    public let date: String          // YYYY-MM-DD
    public let projectCwd: String
    public let eventsCount: Int
    public let sentCount: Int
    public let suppressedCount: Int
    public let promptTokens: Int
    public let completionTokens: Int
    public let llmCalls: Int
}

public struct ProjectRecord: Codable, Sendable {
    public let cwd: String
    public let name: String
    public let customLogoPath: String?
    public let lastSeen: Date
}
```

#### 1c. Tests (`Tests/CodoCoreTests/EventStoreTests.swift`) — NEW

- 内存 SQLite (`:memory:`) 测试 CRUD
- 按 project 过滤查询
- vacuum 清理旧数据
- 并发读写安全

**涉及文件**：
- `Sources/CodoCore/EventStore.swift` — NEW
- `Sources/CodoCore/EventStoreRecords.swift` — NEW
- `Tests/CodoCoreTests/EventStoreTests.swift` — NEW

---

### Phase 2: Guardian stdout 扩展

当前 Guardian stdout 输出的 `GuardianAction` 只有 `{action, title, body}` 三个字段。需要扩展为包含决策上下文。

#### 2a. `guardian/main.ts` — MODIFY

在 LLM 调用完成后，将决策元数据附加到 stdout JSON：

```typescript
// 当前（精简）
const output = { action: "send", title: "...", body: "..." };
process.stdout.write(JSON.stringify(output) + "\n");

// 改造后（丰富）
const output = {
  action: "send",
  title: "...",
  body: "...",
  // New fields:
  tier: classification.tier,
  reason: llmResult.reason,
  model: config.model,
  prompt_tokens: usage?.promptTokens,
  completion_tokens: usage?.completionTokens,
  latency_ms: elapsed,
  session_id: event.session_id,
  cwd: event.cwd,
};
process.stdout.write(JSON.stringify(output) + "\n");
```

#### 2b. `Sources/CodoCore/GuardianAction.swift` — MODIFY

扩展 `GuardianAction` 结构体：

```swift
public struct GuardianAction: Decodable, Sendable {
    public let action: String
    public let title: String?
    public let body: String?
    // New fields (all optional for backward compat)
    public let tier: String?
    public let reason: String?
    public let model: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let latencyMs: Int?
    public let sessionId: String?
    public let cwd: String?

    private enum CodingKeys: String, CodingKey {
        case action, title, body, tier, reason, model
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case latencyMs = "latency_ms"
        case sessionId = "session_id"
        case cwd
    }
}
```

**涉及文件**：
- `guardian/main.ts` — MODIFY（~15 lines）
- `Sources/CodoCore/GuardianAction.swift` — MODIFY（~20 lines added）

---

### Phase 3: DashboardStore 持久化改造

#### 3a. `Sources/Codo/Dashboard/DashboardStore.swift` — MODIFY

核心变更：

1. **注入 EventStore**：
   ```swift
   private let eventStore: EventStore

   init(eventStore: EventStore) {
       self.eventStore = eventStore
       loadProjects()    // 改为从 SQLite 加载
       loadTodayStats()  // 从 SQLite 加载今日统计
   }
   ```

2. **`ingestHookEvent` 双写**：内存 ring buffer（驱动实时 UI）+ SQLite（持久化）

3. **`ingestGuardianAction` 增强**：写入 `guardian_decisions` 表，更新 daily_stats

4. **Projects 迁移**：从 UserDefaults → SQLite。首次启动时检查 UserDefaults 有无旧数据，有则迁移后清除。

5. **统计数据持久化**：`notificationsSent`/`notificationsSuppressed` 从 SQLite 加载，不再重启归零。

#### 3b. `Sources/Codo/AppDelegate.swift` — MODIFY

1. **直接通知也入 DashboardStore**：在 `MessageRouter.notification` 路径中，除了直接发送通知外，也调用 `dashboardStore.ingestDirectNotification()`

2. **EventStore 生命周期**：在 `applicationDidFinishLaunching` 中创建 `EventStore` 实例，传入 `DashboardStore`

**涉及文件**：
- `Sources/Codo/Dashboard/DashboardStore.swift` — MODIFY（~60 lines changed）
- `Sources/Codo/AppDelegate.swift` — MODIFY（~15 lines changed）

---

### Phase 4: guardian.log 轮转

#### 4a. `Sources/CodoCore/GuardianProcess.swift` — MODIFY

在 `readStderrLoop` 中添加 log 轮转逻辑（与 hooks.log 策略一致）：

```swift
private func rotateLogIfNeeded() {
    let logPath = "\(NSHomeDirectory())/.codo/guardian.log"
    let maxSize: UInt64 = 5_000_000 // 5MB
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
          let fileSize = attrs[.size] as? UInt64,
          fileSize > maxSize else { return }
    let backupPath = "\(logPath).1"
    try? FileManager.default.removeItem(atPath: backupPath)
    try? FileManager.default.moveItem(atPath: logPath, toPath: backupPath)
}
```

检查频率：每 1000 行或每 5 分钟检查一次，避免频繁 stat。

**涉及文件**：
- `Sources/CodoCore/GuardianProcess.swift` — MODIFY（~20 lines added）

---

### Phase 5: Dashboard UI 增强

#### 5a. Project Filter — 分项目查看

**`Sources/Codo/Dashboard/Views/DashboardView.swift`** — MODIFY

添加项目过滤器。Sidebar 点击项目时，设置 `DashboardStore.selectedProject`，所有面板根据 filter 展示数据。

```swift
// DashboardStore
var selectedProject: String? = nil  // nil = show all

var filteredEvents: [EventEntry] {
    guard let project = selectedProject else { return events }
    return events.filter { $0.projectCwd == project }
}
```

#### 5b. History View — 历史事件浏览

**`Sources/Codo/Dashboard/Views/HistoryView.swift`** — NEW

新增导航项：Dashboard / **History** / Settings / Logs

| 功能 | 实现 |
|------|------|
| 日期范围选择 | `DatePicker` start/end |
| 项目过滤 | Picker（All / 各项目） |
| 事件类型过滤 | Multi-select toggle（hook / notification / guardian_action） |
| 分页加载 | 每页 50 条，滚动触发加载更多 |
| 决策详情 | 点击 guardian_action 行展开：tier、reason、token 用量 |

数据来源：`EventStore.queryEvents()` + `EventStore.queryDecisions()`

#### 5c. Stats Enhancement — 统计增强

**`Sources/Codo/Dashboard/Views/StatsCard.swift`** — MODIFY

| 当前 | 增强后 |
|------|--------|
| Sent / Suppressed / Active Sessions | + Total Events / LLM Calls / Token Usage |
| 仅当次运行计数 | 今日/7日/30日 切换 |

数据来源：`EventStore.dailyStats()`

#### 5d. LogsView Enhancement — 结构化日志

**`Sources/Codo/Dashboard/Views/LogsView.swift`** — MODIFY

保留当前的原始文本 tail 模式（作为 "Raw" tab），新增 "Structured" tab：

- 从 SQLite 查询结构化事件
- 按项目/类型/时间筛选
- 每行显示：时间 + hook badge + 项目 + summary
- 点击展开完整 raw_json

**涉及文件**：
- `Sources/Codo/Dashboard/Models/NavigationItem.swift` — MODIFY（新增 `.history`）
- `Sources/Codo/Dashboard/Views/DashboardView.swift` — MODIFY
- `Sources/Codo/Dashboard/Views/HistoryView.swift` — NEW
- `Sources/Codo/Dashboard/Views/StatsCard.swift` — MODIFY
- `Sources/Codo/Dashboard/Views/LogsView.swift` — MODIFY
- `Sources/Codo/Dashboard/Views/DetailContainerView.swift` — MODIFY

---

### Phase 6: Data Hygiene

#### 6a. Auto Vacuum

App 启动时：`eventStore.vacuum(keepDays: 30)`

删除超过 30 天的 events 和 guardian_decisions。daily_stats 保留 90 天。

#### 6b. Migration Path

首次启动检测：
1. 如果 `UserDefaults["CodoDashboardProjects"]` 存在 → 迁移到 SQLite `projects` 表 → 清除 UserDefaults key
2. 如果 `~/.codo/codo.db` 不存在 → CREATE TABLE all

#### 6c. guardian.log 结构化双写（可选，Phase 6+）

在 guardian.log 写入文本的同时，通过 Guardian stdout 回传结构化 log 条目给 Swift 侧存入 SQLite。这使得**所有** guardian 日志（不仅仅是决策）都可以在 Dashboard 中结构化查询。

实现方式：新增 stdout action type `"log"`:
```json
{"action": "log", "level": "INFO", "component": "llm", "op": "openai.res", "msg": "...", "data": {...}}
```

**优先级低**，仅在 Phase 1-5 完成后如有需要再考虑。

---

## Atomic Commits Plan

| # | Scope | Description |
|---|-------|-------------|
| 1 | Phase 1a-c | `feat(core): add EventStore SQLite persistence layer` |
| 2 | Phase 2a | `feat(guardian): enrich stdout GuardianAction with decision metadata` |
| 3 | Phase 2b | `feat(core): extend GuardianAction struct with new fields` |
| 4 | Phase 3a | `refactor(dashboard): persist events and stats to SQLite` |
| 5 | Phase 3b | `feat(app): route direct notifications through DashboardStore` |
| 6 | Phase 4a | `feat(core): add guardian.log rotation (5MB max + .1 backup)` |
| 7 | Phase 5a | `feat(dashboard): add project filter across all panels` |
| 8 | Phase 5b | `feat(dashboard): add History view with query and pagination` |
| 9 | Phase 5c | `feat(dashboard): enhance StatsCard with daily/weekly/monthly stats` |
| 10 | Phase 5d | `feat(dashboard): add structured log view in LogsView` |
| 11 | Phase 6a-b | `chore(core): add auto-vacuum and UserDefaults migration` |

---

## Testing Strategy

| Layer | Content | Trigger |
|-------|---------|---------|
| **L1 — UT** | EventStore CRUD, vacuum, migration, GuardianAction decode | `swift test` |
| **L2 — Lint** | SwiftLint + `bun test` (guardian) | pre-commit |
| **L3 — Integration** | 端到端：hook event → SQLite → Dashboard query → 正确展示 | manual |
| **L4 — Regression** | 现有 Dashboard 功能不退化（实时事件流、session 跟踪、settings） | manual |

---

## File Inventory

### New Files (4)

| # | File | ~Lines |
|---|------|--------|
| 1 | `Sources/CodoCore/EventStore.swift` | ~300 |
| 2 | `Sources/CodoCore/EventStoreRecords.swift` | ~80 |
| 3 | `Tests/CodoCoreTests/EventStoreTests.swift` | ~150 |
| 4 | `Sources/Codo/Dashboard/Views/HistoryView.swift` | ~200 |

### Modified Files (8)

| File | Changes |
|------|---------|
| `guardian/main.ts` | Enrich stdout JSON with decision metadata (~15 lines) |
| `Sources/CodoCore/GuardianAction.swift` | Add optional fields + CodingKeys (~20 lines) |
| `Sources/CodoCore/GuardianProcess.swift` | Add log rotation (~20 lines) |
| `Sources/Codo/Dashboard/DashboardStore.swift` | SQLite integration, project migration (~60 lines) |
| `Sources/Codo/AppDelegate.swift` | EventStore init, direct notification routing (~15 lines) |
| `Sources/Codo/Dashboard/Views/StatsCard.swift` | Multi-period stats, token usage (~30 lines) |
| `Sources/Codo/Dashboard/Views/LogsView.swift` | Structured log tab (~80 lines) |
| `Sources/Codo/Dashboard/Models/NavigationItem.swift` | Add `.history` case (~3 lines) |

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| SQLite 写入阻塞主线程 | `EventStore` 内部用串行 `DispatchQueue`，所有 DB 操作异步 |
| Guardian stdout 格式变更导致旧版 Swift 解析失败 | 新字段全部 `Optional`，向后兼容 |
| DB 文件损坏 | WAL 模式 + 应用启动时 `PRAGMA integrity_check` |
| 数据量增长 | 30 天自动 vacuum + daily_stats 聚合历史 |
| Migration 失败 | 迁移前备份 UserDefaults 数据，迁移后校验行数一致才清除旧数据 |

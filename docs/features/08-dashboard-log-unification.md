# 08 — Dashboard & Log Unification

## Problem Statement

Dashboard 和 Guardian 日志系统之间存在**数据断裂**，导致 Dashboard 无法完整展示运行情况和历史记录。

### 现状精确描述

**持久化的数据**：
- `projects: [ProjectInfo]` — 已持久化在 `UserDefaults(key: "CodoDashboardProjects")`，app 重启后保留
- `guardian.log` / `hooks.log` — 纯文本追加，无结构化，无轮转（guardian.log 当前 3.3MB）

**重启丢失的数据**：
- `events: [EventEntry]` — 内存 ring buffer 200 条（DashboardStore.swift L34-36）
- `notificationsSent` / `notificationsSuppressed` — 内存计数器（DashboardStore.swift L29-30）
- `activeSessions: [SessionInfo]` — 内存数组（DashboardStore.swift L39）
- Guardian TS 侧 `StateStore.events: BufferedEvent[]` — 独立的 200 条内存 ring buffer（state.ts L37）
- Guardian TS 侧 `StateStore.projects[].recentNotifications` — 每个项目最近 10 条通知（state.ts L15），不是 200 条 ring buffer

### 现状问题一览

| # | 问题 | 影响 |
|---|------|------|
| 1 | Dashboard events/stats 纯内存，app 重启丢失（projects 已持久化除外） | 无法查看历史事件和累计统计 |
| 2 | guardian.log 无轮转，无限增长 | 磁盘浪费，LogsView 只读尾部 32KB 无法回溯 |
| 3 | Guardian TS 侧 StateStore 和 Swift 侧 DashboardStore 两套独立状态 | LLM token 用量等高价值数据只存在 guardian.log 文本中，Dashboard 看不到 |
| 4 | LogsView 是原始文本尾读，无结构化筛选 | 无法按项目/时间/类型过滤日志 |
| 5 | 直接通知（无 `_hook` 字段）不进入 DashboardStore | 通过 `echo '{"title":...}' \| bun codo.ts` 发送的通知在 Dashboard 不可见 |
| 6 | GuardianAction stdout 不携带决策上下文 | tier/reason/tokens/latency 只写入 stderr 日志，Swift 侧仅知 send/suppress |
| 7 | EventEntry 模型缺少 `projectCwd` | 只有 `projectName`（basename），同名项目不可区分，无法可靠做项目过滤 |
| 8 | CodoMessage 没有 `cwd` 字段 | 直接通知无法归属到具体项目 |
| 9 | Swift 侧无 cwd 规范化 | TS 侧有 `realpathSync` 做 canonicalize，Swift 侧 DashboardStore 直接用原始 cwd，可能一个项目产生多个 key |

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
│                       │   (内存 events)    (直接发送，不记录)    │  ◄── 断裂点❶
│                       │                                         │
│                       ▼                                         │
│                   Guardian (TS)                                  │
│                   ├─ StateStore.events[] (内存 200 条)           │
│                   │  StateStore.projects[].recentNotifications   │
│                   │  (每项目最近 10 条通知，独立于 Swift 侧)     │  ◄── 断裂点❷
│                   ├─ stderr → guardian.log (纯文本，无轮转)      │  ◄── 断裂点❸
│                   └─ stdout → GuardianAction                    │
│                      {action, notification?, reason?}            │
│                      → DashboardStore (仅 send/suppress 计数)   │  ◄── 断裂点❹
│                                                                 │
│  断裂点❶: 直接通知绕过 DashboardStore                            │
│  断裂点❷: TS/Swift 两套状态各管各的，通知历史在 TS 按项目分组     │
│  断裂点❸: guardian.log 是唯一的"持久层"但是纯文本                 │
│  断裂点❹: Guardian 决策的丰富信息(tier/tokens/latency)不回传      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 关键现状代码引用

| 现状 | 文件 | 行号/字段 |
|------|------|-----------|
| `GuardianAction` 结构 | `Sources/CodoCore/GuardianProtocol.swift` L4-14 | `{action, notification: CodoMessage?, reason?}` |
| `GuardianAction` TS 定义 | `guardian/types.ts` L6-10 | `{action, notification?: NotificationPayload, reason?}` |
| `CodoMessage` 无 cwd | `Sources/CodoCore/CodoMessage.swift` L4-11 | 仅 title/body/subtitle/source/sound/threadId |
| `EventEntry` 无 projectCwd | `Sources/Codo/Dashboard/Models/EventEntry.swift` L4-11 | 仅 id/timestamp/hookType/projectName/summary/action |
| guardian.log handle 长期持有 | `Sources/CodoCore/GuardianProcess.swift` L311-353 | `readStderrLoop` 打开 logHandle 直到 EOF，无中途 reopen |
| LogsView 文件监听 | `Sources/Codo/Dashboard/Views/LogsView.swift` L49-68 | `DispatchSource.makeFileSystemObjectSource(.write)` 绑定到 fd，文件 rename 后不会跟踪新文件 |
| TS 侧 cwd 规范化 | `guardian/state.ts` L54-60 | `canonicalizePath()` 用 `realpathSync` |
| Swift 侧无规范化 | `Sources/Codo/Dashboard/DashboardStore.swift` L164-169 | `discoverProject(cwd:)` 直接用原始 cwd 字符串作为 key |
| LLM token 用量仅 stderr | `guardian/llm.ts` | `usage_prompt/usage_completion`（OpenAI）或 `usage_input/usage_output`（Anthropic）只写 logger |

---

## Design Goals

1. **Dashboard 能完整看到运行情况** — 包括直接通知、Guardian 决策详情、LLM token 用量
2. **历史 log 分项目** — 按 project (canonical cwd) 筛选事件，可回溯数天
3. **App 重启不丢关键数据** — events、stats 持久化（projects 已有持久化，保持兼容）
4. **guardian.log 可控** — 轮转 + reopen + LogsView 跟踪新文件
5. **cwd 全链路规范化** — TS / Swift / SQLite 统一 canonical cwd
6. **最小侵入** — 复用现有 IPC 管道，不引入新外部依赖

---

## Architecture

### 新增持久层：SQLite

引入 SQLite 作为结构化持久存储（补充现有 UserDefaults projects 持久化）。

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
    project_cwd TEXT,              -- canonical cwd path (realpath), 直接通知可为 NULL
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
    reason          TEXT,           -- LLM reasoning / suppress reason
    model           TEXT,           -- LLM model used
    prompt_tokens   INTEGER,
    completion_tokens INTEGER,
    latency_ms      INTEGER,
    created_at      TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_decisions_project ON guardian_decisions(project_cwd, timestamp);

-- 每日统计快照（按项目聚合，用于 Dashboard StatsCard 快速加载）
-- events.project_cwd 可为 NULL；daily_stats.project_cwd 不可为 NULL
-- 未归属事件聚合到哨兵值 '__unattributed__'，确保 StatsCard "All" 视图 SUM 完整
CREATE TABLE daily_stats (
    date            TEXT    NOT NULL,  -- YYYY-MM-DD
    project_cwd     TEXT    NOT NULL,  -- canonical cwd 或 '__unattributed__'
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
    cwd             TEXT    PRIMARY KEY,  -- canonical path
    name            TEXT    NOT NULL,
    custom_logo_path TEXT,
    last_seen       TEXT    NOT NULL,
    created_at      TEXT    NOT NULL DEFAULT (datetime('now'))
);
```

### 直接通知的项目归属策略

当前 `CodoMessage` 没有 `cwd` 字段。直接通知（`echo '{"title":...}' | bun codo.ts`）无法可靠归属到项目。

**选择方案 2：给 CodoMessage 新增可选 cwd 字段**

理由：
- CLI 端（`codo.ts`）在 `--hook` 模式下已经从 hook payload 中获取 cwd，普通模式可以从 `process.cwd()` 获取
- 这使得直接通知也能归属到项目，同时保持向后兼容（cwd 可选）
- `source` 字段保留为显示名（basename），`cwd` 作为精确的项目标识符

改动范围：
- `Sources/CodoCore/CodoMessage.swift` — 新增 `public let cwd: String?`
- `cli/codo.ts` — 在 `sendToDaemon` 前统一注入 `cwd: getCwd()`（`getCwd()` = `realpathSync(process.cwd())` + fallback）
- `guardian/types.ts` — `NotificationPayload` 新增可选 `cwd?: string`
- 对于仍然不带 cwd 的直接通知（旧版 CLI），`project_cwd` 在 SQLite `events` 表中存为 NULL

**daily_stats 的 NULL 项目处理**：`events` 表允许 `project_cwd = NULL`，但 `daily_stats` 要求 `project_cwd NOT NULL`（作为主键）。策略：无归属项目的事件在写入 `daily_stats` 时使用哨兵值 `'__unattributed__'`。这样：
- `StatsCard` "All" 视图：`SUM` 全表，包含 `__unattributed__` 行，数据完整不漏
- `StatsCard` 按项目过滤：`WHERE project_cwd = ?`，`__unattributed__` 行不干扰具体项目
- `StatsCard` 可选展示"未归属"项目的独立计数

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
│                       │      │               (CodoMessage.cwd)  │
│                       │      ▼                                  │
│                       │   EventStore (SQLite)  ◄── 持久化       │
│                       │                                         │
│                       ▼                                         │
│                   Guardian (TS)                                  │
│                   ├─ StateStore (内存，不变)                     │
│                   ├─ stderr → guardian.log (保留，加轮转+reopen) │
│                   └─ stdout → GuardianAction                    │
│                      {action, notification?, reason?,            │
│                       meta?: {tier, model,         ◄── 新增字段  │
│                               prompt_tokens, completion_tokens,  │
│                               latency_ms, session_id, cwd}}     │
│                               │                                 │
│                               ▼                                 │
│                   DashboardStore.ingestGuardianAction()          │
│                               │                                 │
│                               ▼                                 │
│                   EventStore.insertDecision()  ◄── 持久化       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### cwd 规范化统一方案

全链路统一使用 canonical (realpath) cwd：

| 层 | 当前状态 | 改造 |
|----|---------|------|
| Guardian TS (`state.ts`) | `realpathSync(cwd)` ✅ 已有 | 不变 |
| Guardian TS → stdout | 原始 cwd 透传 | `emitAction` 前对 cwd 调用 `realpathSync` |
| Swift `DashboardStore` | 原始 cwd 直接用 | 新增 `canonicalizeCwd(_:)` 用 `NSString.resolvingSymlinksInPath`（best-effort symlink 解析） |
| Swift `EventStore` | 不存在 | 所有 INSERT 前统一 canonicalize |
| CLI `codo.ts` | 不涉及（cwd 来自 hook payload 或 `process.cwd()`） | 显式 `realpathSync(process.cwd())`，失败时 fallback 原值。`process.cwd()` 不保证 canonical（如通过 symlink 进入的目录） |

```swift
// Sources/CodoCore/PathUtils.swift — NEW (~10 lines)
import Foundation

/// Best-effort symlink resolution using NSString.resolvingSymlinksInPath.
/// Note: behavior may differ from POSIX realpath(3) in edge cases (e.g. /private prefix handling).
/// If exact parity with TS realpathSync is needed, consider wrapping Darwin.realpath() instead.
/// Falls back to original input on empty result.
public func canonicalizeCwd(_ path: String) -> String {
    let resolved = (path as NSString).resolvingSymlinksInPath
    return resolved.isEmpty ? path : resolved
}
```

---

## Implementation Phases

### Phase 0: 数据模型修正（前置依赖） ✅ DONE

在做任何持久化或过滤之前，先补齐数据模型的缺失字段。

#### 0a. `Sources/Codo/Dashboard/Models/EventEntry.swift` — MODIFY

新增 `projectCwd` 字段，使项目过滤有可靠的精确匹配依据：

```swift
struct EventEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let hookType: String
    let projectCwd: String?     // NEW: canonical cwd for filtering
    let projectName: String?    // display name (basename)
    let summary: String
    let action: String?
}
```

#### 0b. `Sources/CodoCore/CodoMessage.swift` — MODIFY

新增可选 `cwd` 字段（向后兼容）：

```swift
public struct CodoMessage: Codable, Sendable {
    public let title: String
    public let body: String?
    public let subtitle: String?
    public let source: String?
    public let sound: String?
    public let threadId: String?
    public let cwd: String?     // NEW: canonical cwd for project attribution
}
```

#### 0c. `Sources/CodoCore/PathUtils.swift` — NEW

cwd 规范化工具函数（见上文 Architecture 部分）。

#### 0d. `Sources/Codo/Dashboard/DashboardStore.swift` — MODIFY

在 `discoverProject(cwd:)` 和 `ingestHookEvent(_:)` 中调用 `canonicalizeCwd()` 后再使用 cwd。

#### 0e. `cli/codo.ts` — MODIFY

当前 CLI 有两条普通路径（非 `--hook`）：
- **args 路径**（L422-431）：`parseArgs(argv)` 构造 `CodoMessage`
- **stdin 路径**（L432-440）：`parseStdin(stdinText)` 解析 JSON 构造 `CodoMessage`

两条路径最终都汇聚到 L448 `sendToDaemon(message)`。**cwd 注入点应在 `sendToDaemon` 调用前统一补齐**，而不是分别改 `parseArgs` / `parseStdin`，这样覆盖所有 direct notification 路径：

```typescript
import { realpathSync } from "node:fs";

function getCwd(): string | undefined {
  try {
    return realpathSync(process.cwd());
  } catch {
    try { return process.cwd(); } catch { return undefined; }
  }
}

// In main(), before sendToDaemon:
const payload: Record<string, unknown> = { ...message, cwd: getCwd() };
const response = await sendToDaemon(payload);
```

`process.cwd()` 不保证 canonical（如通过 symlink cd 进入的目录），必须显式 `realpathSync` 与 TS 侧 `guardian/state.ts` 的 `canonicalizePath` 行为一致。外层 try/catch 兜底 `process.cwd()` 本身可能抛（如 cwd 已被删除）。

#### 0f. `guardian/types.ts` — MODIFY

`NotificationPayload` 新增 `cwd?: string`。

**涉及文件**：
- `Sources/Codo/Dashboard/Models/EventEntry.swift` — MODIFY
- `Sources/CodoCore/CodoMessage.swift` — MODIFY
- `Sources/CodoCore/PathUtils.swift` — NEW
- `Sources/Codo/Dashboard/DashboardStore.swift` — MODIFY
- `cli/codo.ts` — MODIFY
- `guardian/types.ts` — MODIFY

---

### Phase 1: EventStore — SQLite 持久层 ✅ DONE

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
        project: String? = nil,    // canonical cwd
        type: String? = nil,
        since: Date? = nil,
        limit: Int = 200
    ) -> [EventRecord]
    public func queryDecisions(
        project: String? = nil,    // canonical cwd
        since: Date? = nil,
        limit: Int = 100
    ) -> [DecisionRecord]
    public func dailyStats(
        project: String? = nil,
        days: Int = 7
    ) -> [DailyStatsRecord]
    public func upsertProject(_ project: ProjectRecord)
    public func loadProjects() -> [ProjectRecord]
    public func vacuum(keepDays: Int = 30)
}
```

关键设计决策：
- **线程安全**：通过串行 `DispatchQueue` 序列化所有 DB 操作
- **WAL 模式**：`PRAGMA journal_mode=WAL` — 支持 Dashboard 读取同时写入
- **自动清理**：`vacuum()` 清除超过 30 天的数据，由 app 启动时调用
- **不用 Core Data**：过重，且 Codo 是 `.accessory` 模式无需 iCloud 同步
- **所有 cwd 入库前必须 canonicalize**：调用 `canonicalizeCwd()` 确保一致性

#### 1b. Record types (`Sources/CodoCore/EventStoreRecords.swift`) — NEW

```swift
public struct EventRecord: Codable, Sendable {
    public let timestamp: Date
    public let type: String          // "hook" | "notification" | "guardian_action"
    public let hookType: String?
    public let sessionId: String?
    public let projectCwd: String?   // canonical path, NULL for unattributed notifications
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
    public let cwd: String           // canonical path
    public let name: String
    public let customLogoPath: String?
    public let lastSeen: Date
}
```

#### 1c. Tests (`Tests/CodoCoreTests/EventStoreTests.swift`) — NEW

- 内存 SQLite (`:memory:`) 测试 CRUD
- 按 project 过滤查询（使用 canonical cwd）
- vacuum 清理旧数据
- 并发读写安全

**涉及文件**：
- `Sources/CodoCore/EventStore.swift` — NEW
- `Sources/CodoCore/EventStoreRecords.swift` — NEW
- `Tests/CodoCoreTests/EventStoreTests.swift` — NEW

---

### Phase 2: 扩展现有 GuardianAction 协议 ✅ DONE

当前 `GuardianAction` 在两侧的定义：

**TS 侧** (`guardian/types.ts` L6-10)：
```typescript
export interface GuardianAction {
  action: "send" | "suppress";
  notification?: NotificationPayload;
  reason?: string;
}
```

**Swift 侧** (`Sources/CodoCore/GuardianProtocol.swift` L4-14)：
```swift
public struct GuardianAction: Codable, Sendable {
    public let action: String
    public let notification: CodoMessage?
    public let reason: String?
}
```

扩展方式：新增可选 `meta` 字段包含决策上下文，保持现有 `notification` + `reason` 结构不变。

#### 2a. `guardian/types.ts` — MODIFY

```typescript
export interface GuardianActionMeta {
  tier?: string;           // classification tier
  model?: string;          // LLM model used
  prompt_tokens?: number;  // OpenAI: prompt_tokens, Anthropic: input_tokens
  completion_tokens?: number; // OpenAI: completion_tokens, Anthropic: output_tokens
  latency_ms?: number;     // LLM round-trip time
  session_id?: string;
  cwd?: string;            // canonical cwd
  hook_type?: string;      // triggering hook type
}

export interface GuardianAction {
  action: "send" | "suppress";
  notification?: NotificationPayload;
  reason?: string;
  meta?: GuardianActionMeta;  // NEW
}
```

#### 2b. `guardian/main.ts` — MODIFY

**所有 `emitAction` 调用路径统一走 meta builder**。当前 `processHookEvent` 有三条 `emitAction` 路径（main.ts L136, L144, L83-93），每条都需要补齐基础 meta：

```typescript
import { realpathSync } from "node:fs";

// Safe canonicalize — realpathSync throws if path doesn't exist
function safeCanonicalize(cwd: string | undefined): string | undefined {
  if (!cwd) return undefined;
  try { return realpathSync(cwd); } catch { return cwd; }
}

// 新增 helper：构建基础 meta（所有路径共享）
function buildBaseMeta(event: HookEvent, tier: string): GuardianActionMeta {
  return {
    tier,
    session_id: event.session_id,
    cwd: safeCanonicalize(event.cwd),
    hook_type: event._hook,
  };
}

// 路径 1: LLM 分支 (main.ts L120-136) — 最丰富的 meta
const result = await llmClient.process(event, state);
const elapsed = Math.round(performance.now() - t0);
emitAction({
  ...result,
  meta: {
    ...buildBaseMeta(event, tier),
    model: /* from config */,
    latency_ms: elapsed,
    prompt_tokens: result.usage?.promptTokens,
    completion_tokens: result.usage?.completionTokens,
  },
});

// 路径 2: fallback notification (main.ts L139-145) — 基础 meta + 无 LLM 字段
const notification = fallbackNotification(event);
if (notification) {
  emitAction({
    action: "send",
    notification,
    meta: buildBaseMeta(event, tier),
  });
}

// 路径 3: direct CodoMessage (main.ts L80-96) — 兼容路径（见下方说明）
emitAction({
  action: "send",
  notification: { title: parsed.title, ... },
  meta: { cwd: safeCanonicalize(parsed.cwd as string | undefined) },
});
```

**路径 3 注意**：当前真实架构中，direct notification（无 `_hook` 字段）走的是 `MessageRouter.notification` → `NotificationService.post()` 路径（AppDelegate.swift L257-261），**不会进入 Guardian stdin**。Guardian main.ts L80-96 的 direct CodoMessage 处理是防御性兼容代码。此处补 meta 仅为协议一致性，不是主链路依赖。

#### 2c. `Sources/CodoCore/GuardianProtocol.swift` — MODIFY

扩展 Swift 侧 `GuardianAction`，新增可选 `meta` 嵌套结构：

```swift
public struct GuardianActionMeta: Codable, Sendable {
    public let tier: String?
    public let model: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let latencyMs: Int?
    public let sessionId: String?
    public let cwd: String?
    public let hookType: String?

    private enum CodingKeys: String, CodingKey {
        case tier, model, cwd
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case latencyMs = "latency_ms"
        case sessionId = "session_id"
        case hookType = "hook_type"
    }
}

public struct GuardianAction: Codable, Sendable {
    public let action: String
    public let notification: CodoMessage?
    public let reason: String?
    public let meta: GuardianActionMeta?  // NEW — all optional, backward compat
}
```

#### 2d. `guardian/llm.ts` — MODIFY

修改 `process()` 方法，将 token usage 随结果返回（而不只写到 logger）。具体方式：扩展 `GuardianResult` 或返回包含 usage 的 wrapper。

**涉及文件**：
- `guardian/types.ts` — MODIFY（新增 `GuardianActionMeta`，`GuardianAction.meta`）
- `guardian/main.ts` — MODIFY（填充 meta 字段，~20 lines）
- `guardian/llm.ts` — MODIFY（返回 token usage，~15 lines）
- `Sources/CodoCore/GuardianProtocol.swift` — MODIFY（新增 `GuardianActionMeta`，~25 lines）
- `guardian/main.test.ts` — MODIFY（测试用例适配新 meta 字段）
- `Tests/CodoCoreTests/GuardianProcessTests.swift` — MODIFY（decode 测试适配）

---

### Phase 3: DashboardStore 持久化改造 ✅ DONE

#### 3a. `Sources/Codo/Dashboard/DashboardStore.swift` — MODIFY

核心变更：

1. **注入 EventStore**：
   ```swift
   private let eventStore: EventStore

   init(eventStore: EventStore) {
       self.eventStore = eventStore
       loadProjects()    // 仍从 UserDefaults 加载（Phase 6 再迁移）
       loadTodayStats()  // 从 SQLite 加载今日统计
   }
   ```

2. **`ingestHookEvent` 双写**：
   - 内存 ring buffer 驱动实时 UI（构建 EventEntry 时填充新的 `projectCwd` 字段）
   - SQLite 持久化（`eventStore.insertEvent()`）
   - cwd 在入口处 canonicalize

3. **`ingestGuardianAction` 增强**：
   - 从 `action.meta` 提取决策信息写入 `guardian_decisions` 表
   - 更新 daily_stats
   - `notificationsSent`/`notificationsSuppressed` 同时写 SQLite

4. **统计数据持久化**：`notificationsSent`/`notificationsSuppressed` 启动时从 SQLite `daily_stats` 加载今日数据，不再重启归零。

#### 3b. `Sources/Codo/AppDelegate.swift` — MODIFY

1. **直接通知也入 DashboardStore**：在 `MessageRouter` 的 notification 路径中，除了直接发送通知外，也调用 `dashboardStore.ingestDirectNotification(message:)`。从 `CodoMessage.cwd` 获取项目归属（可为 nil）。

2. **EventStore 生命周期**：在 `applicationDidFinishLaunching` 中创建 `EventStore` 实例，传入 `DashboardStore`。

**涉及文件**：
- `Sources/Codo/Dashboard/DashboardStore.swift` — MODIFY（~60 lines changed）
- `Sources/Codo/AppDelegate.swift` — MODIFY（~15 lines changed）

---

### Phase 4: guardian.log 轮转（rotate + reopen + LogsView 跟踪） ✅ DONE

当前 `GuardianProcess.readStderrLoop` 是 **static 方法**（L311），在进程启动时打开 `logHandle` 并一直持有到 EOF。单纯 rename 文件不够——rename 后旧 handle 仍然写入已移走的 inode，新 guardian.log 文件不会被创建。

同时，`LogsView` 使用 `DispatchSource.makeFileSystemObjectSource(.write)` 监听文件 fd。文件被 rename 后 fd 指向旧 inode，新文件的写入事件不会被触发，tail 视图会断跟。

#### 4a. `Sources/CodoCore/GuardianProcess.swift` — MODIFY

将 `readStderrLoop` 改为支持 rotate + reopen：

```swift
private static func readStderrLoop(pipe: Pipe) {
    let logPath = "\(NSHomeDirectory())/.codo/guardian.log"
    let maxSize: UInt64 = 5_000_000 // 5MB
    let checkInterval = 1000 // every 1000 lines

    var logHandle = openOrCreateLog(at: logPath)
    var lineCount = 0
    // ... existing read loop ...

    // Inside the line processing loop:
    lineCount += 1
    if lineCount % checkInterval == 0 {
        if shouldRotate(path: logPath, maxSize: maxSize) {
            // 1. Close current handle
            logHandle?.closeFile()
            // 2. Rotate: rename current → .1
            let backupPath = "\(logPath).1"
            try? FileManager.default.removeItem(atPath: backupPath)
            try? FileManager.default.moveItem(atPath: logPath, toPath: backupPath)
            // 3. Reopen: create new file + new handle
            logHandle = openOrCreateLog(at: logPath)
        }
    }
}

private static func openOrCreateLog(at path: String) -> FileHandle? {
    let fm = FileManager.default
    if !fm.fileExists(atPath: path) {
        fm.createFile(atPath: path, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
    handle.seekToEndOfFile()
    let marker = "--- guardian stderr log started ---\n"
    handle.write(Data(marker.utf8))
    return handle
}

private static func shouldRotate(path: String, maxSize: UInt64) -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attrs[.size] as? UInt64 else { return false }
    return size > maxSize
}
```

#### 4b. `Sources/Codo/Dashboard/Views/LogsView.swift` — MODIFY

LogsView 的 `DispatchSource` 绑定到文件 fd，文件 rename 后 fd 跟踪旧 inode。需要检测文件 rename 并 reopen：

```swift
// 在 startMonitoring() 中，监听 .rename 事件而不只是 .write
let source = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: fileDescriptor,
    eventMask: [.write, .rename, .delete],  // 扩展监听事件
    queue: .main
)
source.setEventHandler { [self] in
    let event = source.data
    if event.contains(.rename) || event.contains(.delete) {
        // 文件被 rename/delete（rotation 发生），重新建立监听
        stopMonitoring()
        // 短暂延迟等待新文件创建
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            startMonitoring()
        }
    } else {
        loadLogFile()
    }
}
```

**涉及文件**：
- `Sources/CodoCore/GuardianProcess.swift` — MODIFY（~40 lines changed）
- `Sources/Codo/Dashboard/Views/LogsView.swift` — MODIFY（~15 lines changed）

---

### Phase 5: Dashboard UI 增强 ✅ DONE

#### 5a. Project Filter — 分项目查看

**前置条件**：Phase 0 已完成 EventEntry 添加 `projectCwd` 字段。

`DashboardStore` 新增 `selectedProjectCwd: String?`（canonical cwd，nil = show all）。

**`Sources/Codo/Dashboard/Views/SidebarView.swift`** — MODIFY

Sidebar 中项目行点击时设置 `store.selectedProjectCwd`：

```swift
// 当前 (SidebarView.swift L38-40)
ProjectRow(project: project)
    .onTapGesture { selectedProject = project }

// 改造后
ProjectRow(project: project,
           isSelected: store.selectedProjectCwd == project.id)
    .onTapGesture {
        // Toggle filter: tap again to deselect
        store.selectedProjectCwd =
            (store.selectedProjectCwd == project.id) ? nil : project.id
    }
```

**`Sources/Codo/Dashboard/Views/DashboardView.swift`** — MODIFY

所有面板使用 filtered 数据：

```swift
// DashboardStore
var selectedProjectCwd: String? = nil

var filteredEvents: [EventEntry] {
    guard let cwd = selectedProjectCwd else { return events }
    return events.filter { $0.projectCwd == cwd }
}
```

`LiveEventStream`、`ActiveSessionsList`、`StatsCard` 都改为读 `filteredEvents` / filtered sessions。

#### 5b. History View — 历史事件浏览

**`Sources/Codo/Dashboard/Views/HistoryView.swift`** — NEW

新增导航项：Dashboard / **History** / Settings / Logs

| 功能 | 实现 |
|------|------|
| 日期范围选择 | `DatePicker` start/end |
| 项目过滤 | Picker（All / 各项目，使用 canonical cwd 匹配） |
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
- `Sources/Codo/Dashboard/Views/DetailContainerView.swift` — MODIFY（新增 History case + 键盘快捷键调整）
- `Sources/Codo/Dashboard/Views/SidebarView.swift` — MODIFY（项目过滤交互）
- `Sources/Codo/Dashboard/Views/DashboardView.swift` — MODIFY
- `Sources/Codo/Dashboard/Views/HistoryView.swift` — NEW
- `Sources/Codo/Dashboard/Views/StatsCard.swift` — MODIFY
- `Sources/Codo/Dashboard/Views/LogsView.swift` — MODIFY

---

### Phase 6: Data Hygiene ✅ DONE

#### 6a. Auto Vacuum

App 启动时：`eventStore.vacuum(keepDays: 30)`

删除超过 30 天的 events 和 guardian_decisions。daily_stats 保留 90 天。

#### 6b. Migration Path

首次启动检测：
1. 如果 `~/.codo/codo.db` 不存在 → CREATE TABLE all
2. 如果 `UserDefaults["CodoDashboardProjects"]` 存在 → 迁移到 SQLite `projects` 表（cwd 做 canonicalize）→ 校验行数一致后清除 UserDefaults key
3. 迁移前备份 UserDefaults 数据（写入 `~/.codo/projects-backup.json`），迁移失败可回滚

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
| 1 | Phase 0a-f | `feat(core): add projectCwd to EventEntry and cwd to CodoMessage, unify canonicalization` |
| 2 | Phase 1a-c | `feat(core): add EventStore SQLite persistence layer` |
| 3 | Phase 2a-b | `feat(guardian): enrich GuardianAction with decision meta (TS side)` |
| 4 | Phase 2c-d | `feat(core): extend GuardianAction with meta struct (Swift side)` |
| 5 | Phase 3a | `refactor(dashboard): persist events and stats to SQLite` |
| 6 | Phase 3b | `feat(app): route direct notifications through DashboardStore` |
| 7 | Phase 4a-b | `feat(core): add guardian.log rotation with reopen + LogsView re-tracking` |
| 8 | Phase 5a | `feat(dashboard): add project filter across all panels` |
| 9 | Phase 5b | `feat(dashboard): add History view with query and pagination` |
| 10 | Phase 5c | `feat(dashboard): enhance StatsCard with daily/weekly/monthly stats` |
| 11 | Phase 5d | `feat(dashboard): add structured log view in LogsView` |
| 12 | Phase 6a-b | `chore(core): add auto-vacuum and UserDefaults migration` |

---

## Testing Strategy

| Layer | Content | Trigger |
|-------|---------|---------|
| **L1 — UT** | EventStore CRUD, vacuum, migration; GuardianAction decode (Swift + TS); canonicalizeCwd; CodoMessage decode with/without cwd | `swift test` + `bun test` |
| **L2 — Lint** | SwiftLint + Biome | pre-commit |
| **L3 — Integration** | 端到端：hook event → SQLite → Dashboard query → 正确展示; log rotation → reopen → LogsView 跟踪新文件 | manual |
| **L4 — Regression** | 现有 Dashboard 功能不退化（实时事件流、session 跟踪、settings、notification banner） | manual |

---

## File Inventory

### New Files (5)

| # | File | ~Lines | Purpose |
|---|------|--------|---------|
| 1 | `Sources/CodoCore/EventStore.swift` | ~300 | SQLite persistence layer |
| 2 | `Sources/CodoCore/EventStoreRecords.swift` | ~80 | Record types for DB |
| 3 | `Sources/CodoCore/PathUtils.swift` | ~10 | `canonicalizeCwd()` |
| 4 | `Tests/CodoCoreTests/EventStoreTests.swift` | ~150 | EventStore unit tests |
| 5 | `Sources/Codo/Dashboard/Views/HistoryView.swift` | ~200 | History query view |

### Modified Files (17)

| File | Changes |
|------|---------|
| `Sources/Codo/Dashboard/Models/EventEntry.swift` | Add `projectCwd: String?` (~3 lines) |
| `Sources/CodoCore/CodoMessage.swift` | Add `cwd: String?` (~3 lines) |
| `Sources/CodoCore/GuardianProtocol.swift` | Add `GuardianActionMeta` struct + `meta` field (~25 lines) |
| `Sources/CodoCore/GuardianProcess.swift` | Log rotation: rotate + reopen logic (~40 lines) |
| `Sources/Codo/Dashboard/DashboardStore.swift` | SQLite integration, canonicalize cwd, project filter state (~60 lines) |
| `Sources/Codo/AppDelegate.swift` | EventStore init, direct notification routing (~15 lines) |
| `guardian/types.ts` | Add `GuardianActionMeta`, `NotificationPayload.cwd`, update `GuardianAction` (~15 lines) |
| `guardian/main.ts` | Unified meta builder for all emitAction paths (~30 lines) |
| `guardian/llm.ts` | Return token usage from `process()` (~15 lines) |
| `guardian/main.test.ts` | Adapt tests for new meta field (~10 lines) |
| `cli/codo.ts` | Add `getCwd()` helper + inject cwd before `sendToDaemon` (~10 lines) |
| `Sources/Codo/Dashboard/Views/SidebarView.swift` | Project filter tap interaction (~10 lines) |
| `Sources/Codo/Dashboard/Views/DetailContainerView.swift` | Add History case + adjust keyboard shortcuts (~10 lines) |
| `Sources/Codo/Dashboard/Views/StatsCard.swift` | Multi-period stats, token usage (~30 lines) |
| `Sources/Codo/Dashboard/Views/LogsView.swift` | Structured tab + rename/delete event handling (~80 lines) |
| `Sources/Codo/Dashboard/Models/NavigationItem.swift` | Add `.history` case (~5 lines) |
| `Tests/CodoCoreTests/GuardianProcessTests.swift` | GuardianAction decode tests: add meta field coverage (~10 lines) |

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| SQLite 写入阻塞主线程 | `EventStore` 内部用串行 `DispatchQueue`，所有 DB 操作异步 |
| Guardian stdout 格式变更导致旧版 Swift 解析失败 | `meta` 是 `Optional`，旧版不带 meta 的 JSON 仍可正常 decode |
| DB 文件损坏 | WAL 模式 + 应用启动时 `PRAGMA integrity_check` |
| 数据量增长 | 30 天自动 vacuum + daily_stats 聚合历史 |
| Migration 失败 | 迁移前备份到 `~/.codo/projects-backup.json`，校验一致后才清除旧数据 |
| Log rotation 后 LogsView 断跟 | `DispatchSource` 监听 `.rename + .delete`，触发 reopen |
| Log rotation 后 guardian stderr 写入旧 inode | `readStderrLoop` 中 rotate 后立即 `closeFile()` + 创建新 handle |
| 同一项目产生多个 cwd key | 全链路 canonicalize（TS: `realpathSync`, Swift: `canonicalizeCwd`, SQLite: INSERT 前统一处理） |
| 直接通知无 cwd 无法归属项目 | `CodoMessage.cwd` 可选，CLI 端 `realpathSync(process.cwd())` 显式 canonicalize，无 cwd 的旧消息 `project_cwd = NULL`（events 表），daily_stats 用 `'__unattributed__'` 哨兵值聚合 |
| Fallback/direct 分支遗漏 meta | 所有 `emitAction` 路径统一走 `buildBaseMeta()` helper，确保 cwd/session_id/hook_type 不遗漏 |

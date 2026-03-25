# 07 — Guardian Context Expansion

> Expand the Guardian LLM context window from ~1% to ~15% utilization, giving the AI bounded recent history per project so it can understand progress and write context-aware notifications.

## Problem

Guardian makes stateless single-turn LLM calls consuming ~1,500 tokens per request — less than 1% of the configured `contextLimit`. The event buffer holds only 50 entries with aggressive truncation (60-80 chars per summary). As a result, the AI has no sense of project progress — it cannot tell if a test pass is the final step of a 30-minute debug session or a routine check.

Additionally:

- **Notification history is invisible to the AI.** `ProjectState.recentNotifications` stores `{ title, time }` but `serializeForPrompt()` never outputs it. The AI cannot avoid sending duplicate notifications because it doesn't know what it already sent.
- **`contextLimit` is unused.** `GuardianConfig.contextLimit` is read from env (`CODO_CONTEXT_LIMIT`, default 160,000) but no code references it. Buffer sizes and truncation limits are hardcoded constants, ignoring the actual model capacity.
- **No observability.** `llm.ts` logs response token usage but never logs prompt size or estimated token count. Manual verification of context utilization is impossible.

**Current token budget:**

| Component | Chars | ~Tokens |
|-----------|-------|---------|
| System prompt (fixed rules) | ~600 | ~300 |
| State (50 events × 80 chars) | ~4,000 | ~1,000 |
| User message (current event) | ~500 | ~200 |
| **Total** | **~5,100** | **~1,500** |

## Goal

Raise effective context utilization to ~15% of `contextLimit` so the AI receives:

- Longer event summaries (assistant messages, tool outputs, errors) — not 80-char stubs
- Sent notification history per project (title + body + time) — so it can avoid repetition
- Event timeline grouped by project — so it sees each project's story arc
- Current event with full detail (2,000 chars instead of 500)

This is a **bounded recent history** (sliding window), not a complete history. Events beyond the buffer are dropped. No persistence or compression is introduced.

## Design

### Budget Strategy Based on `contextLimit`

Instead of hardcoded constants, derive buffer parameters from `contextLimit`:

```
contextLimit (e.g. 160,000 tokens)
  └─ reserve 1,024 tokens for completion
  └─ reserve ~500 tokens for system prompt (fixed rules)
  └─ reserve ~500 tokens for user message (current event)
  └─ remaining = contextLimit - 2,024 → available for state serialization
```

The `serializeForPrompt()` function receives a `charBudget` derived from `contextLimit`:

```
charBudget = (contextLimit - 2024) * 3
// ~3 chars per token is a rough estimate.
// Chinese text tokenizes denser than English (~1.5-2 chars/token for CJK),
// so 3 is not a tight bound. This is used only as a soft upper limit
// to prevent prompt overflow — not a precise accounting.
```

For the default `contextLimit = 160,000`:
- `charBudget = (160000 - 2024) * 3 = 473,928 chars`
- Even with 200 events × 1,000 chars each = 200k chars, well within budget

For a small model with `contextLimit = 8,000`:
- `charBudget = (8000 - 2024) * 3 = 17,928 chars`
- The serializer would naturally include fewer events from the tail of the buffer

Implementation: `serializeForPrompt()` builds output incrementally. Events are selected per-event (not per-project-group) from most recent to oldest, then grouped by project for rendering. This ensures the most recent events across all projects are always included, regardless of which project they belong to.

The computed `charBudget` is clamped to `[2,000, 600,000]` — the floor prevents negative or excessively small budgets when `contextLimit` itself is tiny (e.g. a 4k model), and the ceiling prevents wasteful over-allocation.

### Key Parameters

| Parameter | Current | New | Rationale |
|-----------|---------|-----|-----------|
| `MAX_EVENTS` | 50 | 200 | Upper bound on in-memory buffer; actual output governed by charBudget |
| `summarizeEvent` stop truncation | 80 chars | 500 chars | Preserve full assistant message |
| `summarizeEvent` command truncation | 60 chars | 200 chars | Show full commands |
| `summarizeEvent` output/error truncation | — / 60 chars | 300 chars | Include meaningful output |
| `summarizeEvent` notification | title only | title + message (200 chars) | Context for notification events |
| `buildUserMessage` field truncation | 500 chars | 2,000 chars | Full current event detail |
| `recentNotifications` | `{ title, time }` | `{ title, body, time }` | AI needs body to detect duplicates |

### Event Grouping: session_id → cwd Resolution

Events without `cwd` (e.g. `session-end`) need to be resolved to their project. The resolution happens at **write time** (in `updateState`), not at serialization time:

1. Maintain a global `sessionToCwd: Map<string, string>` in `StateStore`
2. On `session-start`: record `sessionToCwd.set(event.session_id, canonicalizePath(cwd))`
3. When buffering any event: `BufferedEvent.cwd = (event.cwd ? canonicalizePath(event.cwd) : undefined) ?? store.sessionToCwd.get(event.session_id)` — if `event.cwd` is present it is canonicalized first; if absent, fall back to `sessionToCwd`. This ensures consistency with the canonical paths stored in `sessionToCwd` and `projects`.
4. This survives session_id overwrites in `ProjectState` — the mapping is independent of project state
5. At serialization time, group events by `event.cwd` directly — no reverse lookup needed
6. **Cleanup**: `evictStaleProjects()` also prunes `sessionToCwd` — collect all `sessionId` values still referenced in `store.events` **or** currently attached to a surviving `ProjectState.sessionId`, then delete any `sessionToCwd` entry whose key is not in that union. This prevents premature deletion of a session that is still active on a project but hasn't buffered an event recently. Runs on the same 1-hour cadence as project eviction.

This is more robust than resolving at serialization time from `ProjectState.sessionId`, which can be overwritten when a new session starts on the same project.

### Notification History in Serialization

`serializeForPrompt()` will output per-project sent notification history:

```
### /Users/foo/my-project

#### Sent Notifications
- [2026-03-25T10:01:00Z] 测试通过 — 42个测试全部通过，覆盖率达到95%
- [2026-03-25T10:05:00Z] 构建完成 — Release包编译成功

#### Event Timeline
- [2026-03-25T10:00:00Z] session-start: claude-sonnet-4-6
- [2026-03-25T10:00:30Z] tool: Bash — npm test → 42 tests passed
- [2026-03-25T10:01:00Z] stop: All tests passing after migration...
```

This gives the AI explicit visibility into what notifications it already sent.

### Budget Allocation Strategy

All output sections compete for the same `charBudget`:

1. **Active Projects summary** — rendered first, counted against budget. For typical usage (1-3 projects) this is < 500 chars. If budget is extremely tight, only the most recently active projects are included.
2. **Notification history (priority reserve)** — for each active project, the most recent 3 sent notifications are rendered **before** event selection, counting against budget. This guarantees the AI always sees recent notification history for de-duplication, even on small-context models. If a project has fewer than 3 notifications, all are included. The 3-notification cap keeps the cost bounded (~300-600 chars per project).
3. **Event selection** — iterate events from newest to oldest. For each event, estimate its rendered size. Accumulate until remaining budget is exhausted. This is per-event granularity, not per-project-group, ensuring the most recent events across all projects are always included.
4. **Rendering** — selected events are grouped by their resolved cwd for display (project-grouped timeline), but the selection was done by recency across all projects. Each project section shows "Sent Notifications" (from step 2) followed by "Event Timeline" (from step 3).

## Files to Modify

| File | Change |
|------|--------|
| `guardian/state.ts` | Raise MAX_EVENTS; expand summarizeEvent truncation; add body to recentNotifications; add sessionToCwd map to StateStore; resolve cwd at write time; rewrite serializeForPrompt with charBudget, per-event selection, and project grouping |
| `guardian/llm.ts` | Raise buildUserMessage truncation to 2,000; pass contextLimit to buildSystemPrompt; add context-utilization guidance to prompt; log prompt/user message char length |
| `guardian/state.test.ts` | Update FIFO cap assertion (50→200); update "Recent Events" → "Event History" assertion; add notification history serialization test; add session_id→cwd resolution test; add charBudget truncation test; add multi-session same-cwd test |
| `guardian/llm.test.ts` | Update buildUserMessage truncation test (600→2100 chars); update buildSystemPrompt "Recent Events" → "Event History" assertion; update buildSystemPrompt tests to pass contextLimit |

## Changes

### 1. `guardian/state.ts` — Data Structure and Serialization

#### a) MAX_EVENTS: 50 → 200

```typescript
const MAX_EVENTS = 200;
```

#### b) Add `sessionToCwd` to StateStore

```typescript
export interface StateStore {
  projects: Map<string, ProjectState>;
  events: BufferedEvent[];
  sessionToCwd: Map<string, string>;  // session_id → canonical cwd
  summary: string;
}

export function createStateStore(): StateStore {
  return {
    projects: new Map(),
    events: [],
    sessionToCwd: new Map(),
    summary: "",
  };
}
```

#### c) `updateState()` — populate sessionToCwd + resolve event cwd

In the session-start case:
```typescript
case "session-start":
  if (cwd) {
    store.sessionToCwd.set(event.session_id, canonicalizePath(cwd));
  }
  // ... existing logic ...
```

When buffering events (before the switch), resolve cwd:
```typescript
const resolvedCwd = (cwd ? canonicalizePath(cwd) : undefined)
  ?? store.sessionToCwd.get(event.session_id);

const buffered: BufferedEvent = {
  timestamp: Date.now(),
  hookType: event._hook,
  sessionId: event.session_id,
  cwd: resolvedCwd,
  summary: summarizeEvent(event),
  raw: event as Record<string, unknown>,
};
```

#### d) `recentNotifications` — add body field

```typescript
// In ProjectState interface:
recentNotifications: Array<{ title: string; body?: string; time: number }>;

// In updateState, notification case:
project.recentNotifications.push({
  title: typeof event.title === "string" ? event.title : "Untitled",
  body: typeof event.message === "string" ? truncate(event.message, 200) : undefined,
  time: Date.now(),
});
```

#### e) `evictStaleProjects()` — also prune sessionToCwd

```typescript
export function evictStaleProjects(store: StateStore, maxAgeMs: number): void {
  // ... existing project eviction ...

  // Prune sessionToCwd: keep sessions still in the event buffer
  // OR still attached to a surviving project (active session with no recent events)
  const liveSessionIds = new Set(store.events.map((e) => e.sessionId));
  for (const [, project] of store.projects) {
    if (project.sessionId) liveSessionIds.add(project.sessionId);
  }
  for (const sessionId of store.sessionToCwd.keys()) {
    if (!liveSessionIds.has(sessionId)) {
      store.sessionToCwd.delete(sessionId);
    }
  }
}
```

#### f) `summarizeEvent()` — expand truncation limits

| Hook | Field | Current | New |
|------|-------|---------|-----|
| stop | last_assistant_message | 80 | 500 |
| notification | title only | title + message (200) | |
| post-tool-use | command | 60 | 200 |
| post-tool-use | tool_response | — | 300 (new) |
| post-tool-use-failure | error | 60 | 300 |

```typescript
function summarizeEvent(event: HookEvent): string {
  switch (event._hook) {
    case "stop":
      return `stop: ${truncate(event.last_assistant_message, 500)}`;
    case "notification":
      return `notification: ${event.title ?? "untitled"} — ${truncate(event.message, 200)}`;
    case "post-tool-use":
      return `tool: ${event.tool_name ?? "unknown"} — ${truncate(extractCommand(event), 200)} → ${truncate(event.tool_response, 300)}`;
    case "post-tool-use-failure":
      return `tool-fail: ${event.tool_name ?? "unknown"} — ${truncate(event.error ?? "", 300)}`;
    case "session-start":
      return `session-start: ${event.model ?? "unknown model"}`;
    case "session-end":
      return "session-end";
    default:
      return `${event._hook}`;
  }
}
```

#### g) `serializeForPrompt()` — charBudget + per-event selection + project grouping

New signature:
```typescript
export function serializeForPrompt(
  store: StateStore,
  charBudget: number = 600_000,
): string
```

Logic:

1. **Active Projects section** — render project summaries, count against budget. If budget < project section size, include only the most recently active projects (sorted by `lastEventTime` desc).

2. **Notification history (priority reserve)** — for each active project, render the most recent 3 `recentNotifications` as a "Sent Notifications" sub-section. Count against budget. This runs before event selection to guarantee de-duplication context is always available.

3. **Event selection** — iterate `store.events` from newest to oldest. For each event, compute its rendered line (`- [timestamp] summary`). Accumulate char count. Stop when remaining budget is exhausted. This produces a set of selected events.

4. **Render** — group selected events by `cwd`, output per-project sections with "Sent Notifications" (from step 2) + "Event Timeline" sub-headings. Within each project, events are in chronological order.

### 2. `guardian/llm.ts` — Prompt and Observability

#### a) `buildUserMessage()` — 500 → 2,000 chars

All `stringify(field, 500)` calls change to `stringify(field, 2000)`.

#### b) `buildSystemPrompt(state, contextLimit)` — accept contextLimit, compute charBudget

```typescript
export function buildSystemPrompt(state: StateStore, contextLimit: number = 160_000): string {
  // ~3 chars/token rough estimate; used as soft upper limit only.
  // Clamp to [2_000, 600_000] — floor prevents negative/tiny budgets on
  // ultra-small context models, ceiling prevents wasteful over-allocation.
  const rawBudget = (contextLimit - 2024) * 3;
  const charBudget = Math.min(Math.max(rawBudget, 2_000), 600_000);
  // ... existing fixed rules ...
  const stateStr = serializeForPrompt(state, charBudget);
  // ...
}
```

#### c) Add context-utilization guidance to system prompt

After "通知策略" section:

```typescript
"",
"## 上下文利用",
"- Event History 包含该项目的近期事件流，利用它理解任务进展",
"- Sent Notifications 列出之前已发送的通知，避免发送相似内容",
"- 如果某个任务经历了多次失败后成功，在通知中体现这个过程（如\"经过多轮调试，XXX终于通过\"）",
"- 如果当前事件是一系列操作的最终结果，总结整个过程而非仅描述最后一步",
```

#### d) Observability — log prompt sizes

In both OpenAI and Anthropic client `process()` methods, before the API call:

```typescript
const systemPrompt = buildSystemPrompt(state, config.contextLimit);
const userMessage = buildUserMessage(event);

log.debug("openai.req", "sending request", {
  model: config.model,
  hook: event._hook,
  systemPrompt_chars: systemPrompt.length,
  userMessage_chars: userMessage.length,
  estimated_tokens: Math.round((systemPrompt.length + userMessage.length) / 3),
});
```

### 3. `guardian/state.test.ts` — Update Existing + Add New Tests

#### Update existing tests

| Test | Current Assertion | New Assertion |
|------|------------------|---------------|
| "FIFO drops oldest when exceeding max" (L292) | `≤ 50` | `≤ 200` (and add new test pushing >200) |
| "formats projects and events" (L283) | `toContain("Recent Events")` | `toContain("Event History")` |

#### New tests

- **FIFO cap at 200**: push 210 events, assert `length ≤ 200`
- **Notification body stored**: push notification event with message, assert `recentNotifications[0].body` is set
- **session_id → cwd resolution at write time**: create session-start with cwd="/tmp/proj", then push session-end (no cwd, same session_id). Assert `BufferedEvent.cwd` for the session-end event is "/tmp/proj" (resolved at buffer time).
- **Multi-session same cwd**: start session s1 on /tmp/proj, then start session s2 on /tmp/proj (s1 overwritten in ProjectState). Push events for s1 after overwrite. Assert s1 events still resolve to /tmp/proj via `sessionToCwd` map (not broken by ProjectState.sessionId overwrite).
- **charBudget truncation**: fill store with many large events (e.g. 100 events with 500-char summaries), call `serializeForPrompt(store, 5000)` with small budget. Assert output length ≤ ~5000. Assert output contains the most recent event but not the oldest.
- **Notification history in output**: push notification event with title + body, assert serialized output contains "Sent Notifications" section with both title and body.
- **sessionToCwd cleanup**: populate sessionToCwd with three entries: one referenced in `store.events`, one attached to a surviving `ProjectState.sessionId` but not in events, and one completely orphaned. Call `evictStaleProjects()`. Assert the orphaned entry is pruned, while both the event-referenced and project-referenced entries survive.
- **cwd canonicalization consistency**: push an event with a non-canonical cwd (e.g. trailing slash `/tmp/proj/` or `..` segment `/tmp/foo/../proj`). Assert `BufferedEvent.cwd` is the canonicalized form (e.g. `/tmp/proj`), matching the key in `sessionToCwd` and `projects`.

### 4. `guardian/llm.test.ts` — Update Existing Tests

| Test | Change |
|------|--------|
| "includes role and tools with state" (L128) | `toContain("Recent Events")` → `toContain("Event History")` |
| "post-tool-use with long object tool_response → truncated" (L567) | Change `"x".repeat(600)` → `"x".repeat(2100)`, assert output line length < 2020 |
| `buildSystemPrompt` tests | Update to pass `contextLimit` parameter where applicable |

## Atomic Commits

| # | Scope | Files |
|---|-------|-------|
| 1 | Expand event buffer, summary truncation, notification body, sessionToCwd map | `state.ts`, `state.test.ts` |
| 2 | Per-event budget selection + project-grouped serialization with charBudget + notification history | `state.ts`, `state.test.ts` |
| 3 | Expand buildUserMessage truncation, contextLimit threading, prompt guidance, observability | `llm.ts`, `llm.test.ts` |

## Testing

### Unit tests

```bash
cd /Users/nocoo/workspace/personal/codo && bun test
cd cli && bun test
```

### Manual verification

After deploying changes:

```bash
# Restart guardian
pkill -f "guardian/main.ts"

# Tail guardian log
tail -f ~/.codo/guardian.log
```

Verify the following in the log output:

1. **Observability fields appear**: `systemPrompt_chars`, `userMessage_chars`, and `estimated_tokens` fields are present in `openai.req` / `anthropic.req` log entries
2. **Token growth**: send 3-5 events in sequence, confirm `estimated_tokens` increases with each call (more history = bigger prompt)
3. **Notification quality**: after building up event history, trigger a stop event and check that the resulting notification references prior context (e.g. mentions the debug journey, not just the final outcome)

## Status

- [x] Commit 1: Expand event buffer, summary truncation, notification body, sessionToCwd map
- [x] Commit 2: Per-event budget selection + project-grouped serialization with charBudget + notification history
- [x] Commit 3: Expand buildUserMessage truncation, contextLimit threading, prompt guidance, observability
- [x] All tests passing
- [ ] Manual verification: observability fields present, estimated_tokens grows, AI references prior context

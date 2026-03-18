# 02 - AI Guardian

> An AI-powered notification guardian that maintains context, rewrites notifications intelligently, and replaces raw message forwarding with semantically aware notification delivery.

## Problem

Codo v1 is a dumb pipe: CLI sends a message, daemon displays it as-is. In AI-powered development workflows, agents (Claude Code, Cursor, etc.) generate a flood of notifications — build results, test progress, deploy status, review requests — often redundant, poorly worded, or lacking context. Users either drown in noise or miss critical updates.

## Vision

An always-on AI guardian that sits between the CLI and the notification system. It maintains a running context of what the user is working on, understands which notifications are updates to an ongoing task vs. new events, and rewrites raw messages into concise, context-aware notifications before delivery.

**Before (dumb pipe):**
```
CLI: "Build Failed" "error in auth.swift:42"           → notification: "Build Failed — error in auth.swift:42"
CLI: "Build Failed" "error in auth.swift:42, db.swift:7" → notification: "Build Failed — error in auth.swift:42, db.swift:7"
CLI: "Build Failed" "error in auth.swift:42"           → notification: "Build Failed — error in auth.swift:42"
```
→ 3 separate, repetitive notifications

**After (AI Guardian):**
```
CLI: "Build Failed" "error in auth.swift:42"           → notification: "❌ Build Failed — 1 error in auth.swift"
CLI: "Build Failed" "error in auth.swift:42, db.swift:7" → [updates previous] "❌ Build Failed — 2 errors (auth.swift, db.swift)"
CLI: "Build Failed" "error in auth.swift:42"           → [suppressed — same error, already notified]
```
→ 1 notification, updated once, duplicate suppressed

## Architecture

### Process Model

```
┌──────────────────────────────────────────────────────┐
│  Swift Daemon (Codo.app)                             │
│                                                      │
│  NSStatusItem ─── NSMenu ─── Settings Window         │
│                                                      │
│  SocketServer ──┬── Guardian OFF → NotificationService│
│                 │                                    │
│                 └── Guardian ON  → stdin ──┐         │
│                                            │         │
│  ┌─────────────────────────────────────────┤         │
│  │  TS/Bun Child Process (Guardian)        │         │
│  │                                         │         │
│  │  stdin (JSON-RPC) ◄────────────────────┘         │
│  │       │                                           │
│  │       ▼                                           │
│  │  AI Loop                                          │
│  │   ├── Context Manager (message history)           │
│  │   ├── LLM Client (OpenAI-compatible)              │
│  │   └── Tool: send_notification ──► stdout ─────────┤
│  │                                           │       │
│  └───────────────────────────────────────────┘       │
│                                                      │
│  stdout (JSON-RPC) ──► NotificationService           │
└──────────────────────────────────────────────────────┘
```

**Key design: the Guardian is a child process of the Swift daemon, communicating via stdin/stdout JSON-RPC.** This matches the LSP/MCP pattern — battle-tested, language-agnostic, crash-isolated.

### Why a Separate Process

| Concern | Benefit |
|---------|---------|
| **SDK ecosystem** | openai npm package is first-class; Swift LLM SDKs are third-party |
| **Iteration speed** | TS changes take effect immediately; Swift requires recompilation |
| **Fault isolation** | Guardian crash doesn't take down the daemon or menubar icon |
| **Context management** | JS/TS has mature streaming + token counting libraries |

### Message Flow

All incoming CLI messages pass through the Guardian when enabled:

```
CLI ──► UDS ──► SocketServer ──┬──► respond ok to CLI (sync, immediate)
                               │
                               └──► Guardian (stdin, async)
                                        │
                                        ├── LLM: analyze + rewrite
                                        │
                                        ├── Tool call: send_notification
                                        │        │
                                        │        ▼ (stdout)
                                        │   NotificationService ──► macOS toast
                                        │
                                        └── Or: suppress (no notification)
```

**Latency budget**: The LLM call adds 0.5–2s to each notification. This is acceptable because:
1. Notifications are not latency-critical (unlike UI interactions)
2. The daemon responds `ok` to the CLI **synchronously and immediately** — the CLI does not wait for AI processing
3. The Guardian processes the message asynchronously after the CLI has already exited

**Response model**: The daemon acknowledges the CLI immediately (`ok: true`), then forwards the message to the Guardian. The CLI's exit code reflects "message received by daemon", not "notification delivered". This keeps the CLI fast and decoupled from AI latency.

**Fallback**: If the Guardian process is down or the LLM call fails, the daemon falls back to raw notification delivery (same as Guardian OFF).

### Guardian AI Loop

The Guardian maintains a **persistent context** across messages:

```
System Prompt (fixed)
├── Role: "You are a notification guardian..."
├── Tool definitions: send_notification, update_notification, suppress
├── Rules: dedup, summarize, group by thread
└── Current notification state (managed by context manager)

Message History (rolling)
├── [incoming message 1] → [LLM response + tool calls]
├── [incoming message 2] → [LLM response + tool calls]
├── ...
└── [incoming message N] → [LLM response + tool calls]
```

**Context window management** (160K threshold):
- Track token count after each exchange
- When approaching 160K: summarize older messages into a compact state snapshot
- Replace old messages with the summary, preserving recent messages in full
- The summary captures: active tasks, recent notification state, key decisions

**LLM Tool definitions**:

| Tool | Parameters | Purpose |
|------|-----------|---------|
| `send_notification` | title, body, subtitle, sound, threadId | Send a new notification |
| `suppress` | reason | Suppress this message (dedup, noise) |

Notification replacement (`update_notification` with stable IDs) is a future enhancement. For v1, the Guardian can only send new notifications or suppress — keeping the tool surface minimal.

### Configuration

**Settings stored in**:
- **API key** → macOS Keychain (encrypted, per-app)
- **Other settings** → UserDefaults (model name, base URL, guardian on/off, rules)

**Settings UI**: NSWindow panel opened from menubar menu "Settings..."

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| Guardian Enabled | Toggle | OFF | Master on/off switch |
| API Key | SecureField | — | OpenAI-compatible API key |
| Base URL | TextField | `https://api.openai.com/v1` | API endpoint (override for compatible providers) |
| Model | TextField | `gpt-4o-mini` | Model name |
| Context Limit | Number | 160000 | Token limit before context compression |

**Menubar menu (extended)**:
```
┌──────────────────────┐
│ Codo v0.2.0          │
│──────────────────────│
│ ☐ AI Guardian        │  ← toggle on/off
│ ☐ Launch at Login    │
│ Settings...          │  ← opens NSWindow
│──────────────────────│
│ Quit Codo         ⌘Q │
└──────────────────────┘
```

### Communication Protocol (Daemon ↔ Guardian)

JSON-RPC 2.0 over stdin/stdout, newline-delimited:

**Daemon → Guardian (stdin):**
```json
{"jsonrpc":"2.0","id":1,"method":"process_message","params":{"title":"Build Failed","body":"error in auth.swift:42","subtitle":"❌ Error","sound":"default","threadId":"build"}}
```

**Guardian → Daemon (stdout, tool execution request):**
```json
{"jsonrpc":"2.0","id":1,"result":{"action":"send","notification":{"title":"❌ Build Failed","body":"1 error in auth.swift","subtitle":"❌ Error","sound":"default","threadId":"build"}}}
```

**Or suppress:**
```json
{"jsonrpc":"2.0","id":1,"result":{"action":"suppress","reason":"duplicate of previous build failure"}}
```

### Technology Choices

| Component | Choice | Rationale |
|-----------|--------|-----------|
| LLM SDK | `openai` npm package | Official, first-class baseURL support, streaming, tool calling |
| Runtime | Bun | Already required for CLI, fast startup |
| IPC | stdin/stdout JSON-RPC | LSP/MCP proven pattern, zero network config |
| Keychain | Security.framework via Swift | Native, encrypted, per-app isolated |
| Settings UI | AppKit (NSWindow + NSViewController) | Consistent with existing pure-AppKit approach |
| Token counting | `tiktoken` (via js-tiktoken) | Accurate token estimation for context management |

### Error Handling & Resilience

| Scenario | Behavior |
|----------|----------|
| Guardian process crashes | Daemon restarts it (max 3 retries, then disable) |
| LLM API timeout (>10s) | Fall back to raw notification delivery |
| LLM API error (4xx/5xx) | Fall back to raw notification delivery + log |
| API key not configured | Guardian disabled, raw delivery |
| Invalid LLM response | Fall back to raw delivery |
| Context overflow | Compress and continue |

**Principle: notification delivery never fails because of the Guardian.** If AI processing fails for any reason, the original message is delivered as-is.

### Guardian Process Lifecycle

The Guardian process starts **immediately on daemon launch** (when enabled) and stays warm:

```
Daemon launch
    │
    ├── Guardian enabled?
    │   ├── Yes → spawn TS/Bun child process → ready
    │   └── No  → skip
    │
    ├── Message arrives
    │   ├── Guardian alive → forward via stdin
    │   └── Guardian dead  → raw delivery + attempt restart
    │
    ├── Guardian crashes
    │   ├── retry count < 3 → restart immediately
    │   └── retry count ≥ 3 → disable Guardian, log error
    │
    └── Daemon shutdown
        └── SIGTERM to Guardian → clean exit
```

**Always warm** — avoids cold-start latency on first message. The Guardian process is lightweight (Bun runtime + idle event loop) when no messages are being processed.

## Scope

### In Scope (Phase 2)

- Guardian TS/Bun process with AI loop
- OpenAI-compatible LLM integration (custom base URL + model)
- Context maintenance across messages with auto-compression
- Notification rewriting (title, body, subtitle inference)
- Deduplication and suppression of redundant notifications
- Notification update (replace previous notification for same thread)
- Settings UI (API key, base URL, model, guardian toggle)
- Keychain storage for API key
- Daemon ↔ Guardian JSON-RPC protocol
- Process lifecycle management (spawn, restart, shutdown)
- Graceful fallback to raw delivery on any AI failure

### Out of Scope (Future)

- Custom user rules / prompt customization
- Multiple LLM provider profiles
- Notification action buttons (approve/reject from notification)
- Usage tracking / token budget
- Notification history / log viewer
- Rich media in notifications
- Cross-device sync

## Design Decisions

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| 1 | Response timing | **Sync** — daemon responds `ok` to CLI immediately, Guardian processes async | CLI stays fast (<50ms), decoupled from LLM latency |
| 2 | Notification replacement | **Not in v1** — Guardian can only send new or suppress | Keep tool surface minimal; update_notification is future work |
| 3 | Guardian startup | **Always warm** — spawn on daemon launch | Avoids cold-start latency on first message |

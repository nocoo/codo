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
CLI: "Build Failed" "error in auth.swift:42, db.swift:7" → notification: "❌ Build Failed — now 2 errors (auth.swift, db.swift)"
CLI: "Build Failed" "error in auth.swift:42"           → [suppressed — same error, already notified]
```
→ 2 notifications (second one rewrites with accumulated context), duplicate suppressed

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
│  │   ├── Working State Store (projects, sessions)    │
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

### Guardian Internal State Model

The Guardian is not a chatbot — it's a **state machine** that maintains structured knowledge about ongoing projects and sessions. The LLM reads this state on each invocation and decides how to handle the incoming event.

#### Three-Layer State

```
┌─────────────────────────────────────────────────────┐
│  Layer 1: Working State Store (persistent, structured) │
│                                                       │
│  Projects                                             │
│  ├── /Users/you/project-a  (cwd → project identity)  │
│  │   ├── session: "abc123" (active Claude session)    │
│  │   ├── task: "refactoring auth module"              │
│  │   ├── last_status: "build passed, 42 tests green"  │
│  │   └── recent_notifications: [{title, time}, ...]   │
│  │                                                     │
│  └── /Users/you/project-b                              │
│      ├── session: "def456"                             │
│      ├── task: "adding pagination to API"              │
│      └── ...                                           │
├─────────────────────────────────────────────────────────┤
│  Layer 2: Recent Event Buffer (rolling, raw events)     │
│                                                         │
│  Last ~50 events with full payloads:                    │
│  ├── [PostToolUse: "npm test" → 42 passed]             │
│  ├── [PostToolUse: "git commit" → "fix auth"]          │
│  ├── [Stop: "Completed refactoring..."]                │
│  └── ...                                                │
├─────────────────────────────────────────────────────────┤
│  Layer 3: Summary Snapshot (compressed, LLM-generated)  │
│                                                         │
│  "User is working on two projects: project-a has an     │
│   active auth refactor (tests passing), project-b is    │
│   adding API pagination (last build failed 2h ago)."    │
└─────────────────────────────────────────────────────────┘
```

#### Project Identity

The Guardian identifies projects by **`cwd`** (working directory) from hook events. This is the most reliable project key — different Claude Code sessions in the same directory are part of the same project.

| Hook Field | Maps To | Purpose |
|------------|---------|---------|
| `cwd` | **Project** | Primary key — identifies which project this event belongs to |
| `session_id` | **Session** | Correlates events within one Claude Code conversation |
| `hook_event_name` | **Event type** | Determines how to update state |
| `transcript_path` | **Context source** | On-demand deep context (read selectively) |

#### State Update Rules

| Event | State Update |
|-------|-------------|
| `SessionStart` | Register session under project (by cwd), record model |
| `PostToolUse` | Update project's last_status for significant results (test/build/git) |
| `PostToolUseFailure` | Update project's last_status with error info |
| `Stop` | Update project's task description from `last_assistant_message` |
| `Notification` | Enrich with project context, record in recent_notifications |
| `SessionEnd` | Mark session as ended (project persists) |

#### How State Feeds the LLM

On each LLM invocation, the system prompt includes a **serialized snapshot** of the Working State Store:

```
System Prompt (assembled per invocation)
├── Role + rules (fixed)
├── Tool definitions: send_notification, suppress (fixed)
├── Working State: (serialized from Layer 1)
│   "Active projects:
│    - /Users/you/project-a: refactoring auth, session abc123,
│      last status: 42 tests passed, 2 notifications sent today
│    - /Users/you/project-b: adding pagination, session def456,
│      last status: build failed 1h ago"
└── Recent events: (last 5-10 from Layer 2, for immediate context)
```

The LLM sees structured state, not a chat transcript. This is fundamentally different from "message history" — the Guardian **knows** what's happening across projects.

#### Context Window Management (160K threshold)

The three-layer model keeps context bounded:

- **Layer 1 (Working State Store)**: Fixed-size structured data. ~2-5K tokens. Never needs compression — stale projects are evicted after inactivity timeout.
- **Layer 2 (Recent Event Buffer)**: Rolling window of last ~50 raw events. ~10-30K tokens. Oldest events are dropped as new ones arrive. No LLM call needed — pure FIFO.
- **Layer 3 (Summary Snapshot)**: Generated when Layer 2 drops events that contained important state. The LLM summarizes the dropped events into a compact paragraph (~500 tokens) that updates Layer 1's task/status fields.

**Token budget**:
```
System prompt (role + rules + tools):     ~2K tokens
Working State Store (Layer 1):            ~2-5K tokens
Recent Event Buffer (Layer 2):            ~10-30K tokens
LLM response + tool calls:               ~1-2K tokens
────────────────────────────────────────────────────
Total per invocation:                     ~15-40K tokens
```

This is well within even small model context windows. The 160K limit is a safety cap for edge cases (extremely verbose tool outputs in the event buffer), not the normal operating range.

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

## Data Sources: Claude Code Hooks

The primary data source for the Guardian is **Claude Code hooks** — lifecycle events that trigger CLI calls with rich JSON context. Understanding what data is available at each hook point is critical for the Guardian's context-building strategy.

### Hook Integration Architecture

```
Claude Code
    │
    ├── Notification hook ──► codo CLI (stdin JSON) ──► daemon ──► Guardian
    ├── Stop hook ──────────► codo CLI (stdin JSON) ──► daemon ──► Guardian
    ├── PostToolUse hook ───► codo CLI (stdin JSON) ──► daemon ──► Guardian
    └── SessionStart hook ──► codo CLI (stdin JSON) ──► daemon ──► Guardian
```

Each hook receives a **JSON payload on stdin** containing event-specific data plus common fields available on every event.

### Common Fields (All Events)

Every hook invocation includes:

| Field | Type | Description | Guardian Value |
|-------|------|-------------|----------------|
| `session_id` | `string` | Unique session identifier | **High** — correlate messages from the same session |
| `transcript_path` | `string` | Absolute path to conversation JSON file | **Critical** — full conversation context on demand |
| `cwd` | `string` | Current working directory | **Medium** — identifies which project |
| `hook_event_name` | `string` | Event type that triggered this hook | **High** — determines message semantics |

**`transcript_path` is the most powerful field** — it points to the complete conversation history on disk. The Guardian can read this file to understand the full context of what Claude is doing, without needing to reconstruct it from individual hook events.

**Transcript read strategy** (to avoid "every event scans the full file"):

| Scenario | Read Strategy |
|----------|---------------|
| `PostToolUse` / `PostToolUseFailure` | **Never read transcript** — the hook payload itself contains all needed data (tool_input, tool_response/error) |
| `Stop` | **Read last 3-5 turns** if `last_assistant_message` alone is insufficient for generating a good notification |
| `Notification` | **Read last 3-5 turns** — Notification payloads are sparse (just message + type), so context from transcript helps the Guardian understand *why* the notification is happening |
| `SessionStart` | **Read last 1 turn** (if resuming) to understand what the session was doing |
| Context gap | If the Guardian's Working State Store has no entry for this project/session, **read last 10 turns** on the first event to bootstrap state |

**Default: do not read transcript.** Most events carry enough data in their hook payload. Transcript reads are the exception, not the rule. The Guardian tracks a `transcript_last_read_offset` per session to avoid re-reading already-processed content.

### Hook Events for Guardian

We use 4 primary hook events, each providing different contextual information:

#### 1. `Notification` — Primary notification trigger

The most direct hook. Fires when Claude Code itself wants to notify the user.

```json
{
  "session_id": "abc123",
  "transcript_path": "/path/to/conversation.json",
  "cwd": "/Users/you/project",
  "hook_event_name": "Notification",
  "message": "Claude needs your permission to use Bash",
  "title": "Permission needed",
  "notification_type": "permission_prompt"
}
```

| notification_type | Meaning | Guardian Strategy |
|-------------------|---------|-------------------|
| `permission_prompt` | Claude needs user to approve a tool use | High priority — user action needed |
| `idle_prompt` | Claude is waiting for user input | Medium — may suppress if recent |
| `auth_success` | Authentication completed | Low — usually transient |
| `elicitation_dialog` | MCP server requesting user input | High — user action needed |

**Data richness: Low.** Only `message`, `title`, and `notification_type`. The Guardian must rely on its maintained context (from other hook events) to understand what this notification is about.

#### 2. `Stop` — Task completion signal

Fires when Claude finishes a response. Contains the **last assistant message** — the richest single piece of context.

```json
{
  "session_id": "abc123",
  "transcript_path": "/path/to/conversation.json",
  "cwd": "/Users/you/project",
  "hook_event_name": "Stop",
  "stop_hook_active": false,
  "last_assistant_message": "I've completed the refactoring of the authentication module. All 42 tests pass. Here's a summary of changes:\n- Extracted AuthService from AuthController\n- Added token refresh logic\n- Updated 3 test files"
}
```

**Data richness: High.** `last_assistant_message` is a natural-language summary of what Claude just did. This is the **best source for generating meaningful notifications** — the Guardian can extract the key outcome and rewrite it as a concise toast.

#### 3. `PostToolUse` — Operation result tracking

Fires after each successful tool call. Provides the tool name, input, and response.

```json
{
  "session_id": "abc123",
  "transcript_path": "/path/to/conversation.json",
  "cwd": "/Users/you/project",
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_input": { "command": "npm test", "timeout": 30000 },
  "tool_use_id": "toolu_abc123",
  "tool_response": "Test Suites: 12 passed, 12 total\nTests: 42 passed, 42 total"
}
```

Common tool names and what they tell the Guardian:

| tool_name | What it reveals | Example notification |
|-----------|-----------------|---------------------|
| `Bash` (test commands) | Test results | "✅ 42 tests passed" |
| `Bash` (build commands) | Build status | "❌ Build failed — 3 errors" |
| `Bash` (git commands) | Git operations | "Committed: fix auth token refresh" |
| `Edit` / `Write` | Files being modified | (usually suppress — too granular) |
| `Agent` | Sub-agent spawned | (suppress — internal detail) |

**Data richness: Very High** but **very verbose**. The Guardian should selectively process PostToolUse events — test results, build outputs, and git operations are valuable; individual file edits are noise.

**Performance concern**: PostToolUse fires for *every* tool call, which can be dozens per task. The Guardian must filter aggressively or batch these events rather than calling the LLM for each one.

#### 4. `PostToolUseFailure` — Error tracking

Fires when a tool call fails. Provides error information.

```json
{
  "session_id": "abc123",
  "transcript_path": "/path/to/conversation.json",
  "cwd": "/Users/you/project",
  "hook_event_name": "PostToolUseFailure",
  "tool_name": "Bash",
  "tool_input": { "command": "npm test" },
  "tool_use_id": "toolu_abc123",
  "error": "Command failed with exit code 1:\n\nFAIL src/auth.test.ts\n  ● AuthService > should refresh token",
  "is_interrupt": false
}
```

**Data richness: High.** Failures are almost always worth notifying about. `is_interrupt` distinguishes user-initiated cancellation from real errors.

#### 5. `SessionStart` / `SessionEnd` — Session lifecycle

```json
// SessionStart
{
  "session_id": "abc123",
  "transcript_path": "/path/to/conversation.json",
  "cwd": "/Users/you/project",
  "hook_event_name": "SessionStart",
  "source": "startup",
  "model": "claude-sonnet-4-6"
}

// SessionEnd
{
  "session_id": "abc123",
  "hook_event_name": "SessionEnd",
  "reason": "prompt_input_exit"
}
```

**Guardian use**: SessionStart lets the Guardian know a new context is beginning (reset or correlate). SessionEnd signals cleanup. These are low-frequency, low-cost events.

### Recommended Hook Configuration

The following Claude Code hook configuration routes events to Codo:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [{
          "type": "command",
          "command": "cat | codo --hook stop"
        }]
      }
    ],
    "Notification": [
      {
        "hooks": [{
          "type": "command",
          "command": "cat | codo --hook notification"
        }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{
          "type": "command",
          "command": "cat | codo --hook post-tool-use",
          "async": true
        }]
      }
    ],
    "PostToolUseFailure": [
      {
        "hooks": [{
          "type": "command",
          "command": "cat | codo --hook post-tool-use-failure",
          "async": true
        }]
      }
    ],
    "SessionStart": [
      {
        "hooks": [{
          "type": "command",
          "command": "cat | codo --hook session-start",
          "async": true
        }]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [{
          "type": "command",
          "command": "cat | codo --hook session-end",
          "async": true
        }]
      }
    ]
  }
}
```

**Design notes**:
- `cat |` pipes the JSON stdin to `codo`
- `--hook <type>` is a **new CLI flag** that tells codo to forward the full hook JSON to the Guardian instead of treating it as a simple notification
- `async: true` on PostToolUse/Failure and session events — these are observational, shouldn't block Claude Code
- `Stop` and `Notification` are **synchronous** — we want to ensure the notification fires before the user context-switches
- `PostToolUse` matcher is `"Bash"` only — Edit/Write/Read events are too noisy for notification purposes

### CLI Extension: `--hook` Flag

The existing `codo` CLI needs a new `--hook <event-type>` flag that:

1. Reads the full Claude Code hook JSON from stdin
2. Forwards it as-is to the daemon (which passes it to the Guardian)
3. The Guardian receives the raw hook data with all fields intact

This is different from the existing stdin JSON mode:
- **Existing**: `echo '{"title":"..."}' | codo` — user constructs a CodoMessage
- **New**: `cat | codo --hook stop` — raw Claude Code hook payload forwarded to Guardian

The wire format between CLI → daemon is extended to a **union message type**:

```json
// Type A: CodoMessage (direct notification, unchanged)
{"title": "Build Done", "body": "42 tests passed"}

// Type B: HookEvent (for Guardian processing, new)
{"_hook": "stop", "session_id": "abc123", "transcript_path": "...", "last_assistant_message": "..."}
```

**This is a discriminated union, not an extension of CodoMessage.** The `_hook` field is the discriminator:
- **Absent** → `CodoMessage` — handled by the existing notification path
- **Present** → `HookEvent` — a completely different type routed to the Guardian

On the Swift side, the daemon's message codec must decode the raw JSON, check for `_hook`, and dispatch to the appropriate handler:

```
SocketServer receives JSON
    │
    ├── has "_hook" field?
    │   ├── Yes → decode as HookEvent → route to Guardian
    │   └── No  → decode as CodoMessage → route to NotificationService (existing path)
```

This keeps `CodoMessage` unchanged — no new fields, no ambiguity. The two types share the same transport (UDS + JSON + newline) but are structurally distinct. The daemon handler becomes a **router** that dispatches based on message type.

When the daemon receives a `HookEvent`:
- Guardian ON → forward to Guardian for AI processing
- Guardian OFF → extract best-effort title/body from hook payload and deliver as raw notification via the existing CodoMessage path

### Data Flow Summary

| Hook Event | Frequency | Richness | Latency Sensitivity | Guardian Strategy |
|------------|-----------|----------|---------------------|-------------------|
| `Stop` | Low (1 per task) | **Very High** — full summary | Medium (sync) | Always process — generate notification from assistant message |
| `Notification` | Low | Low — title + type only | Medium (sync) | Enrich with maintained context, forward |
| `PostToolUse` | **Very High** (per tool call) | High — full tool I/O | Low (async) | **Batch + filter** — only process Bash results, accumulate for context |
| `PostToolUseFailure` | Low | High — error details | Low (async) | Always process — errors are important |
| `SessionStart` | Very Low | Low | None (async) | Context reset / correlation |
| `SessionEnd` | Very Low | Minimal | None (async) | Cleanup |

### Performance Strategy

PostToolUse is the hot path — potentially dozens of events per task. The Guardian must handle this efficiently:

1. **Filter at hook level**: Only Bash tool calls are hooked (matcher: `"Bash"`). Edit/Write/Read are excluded.
2. **Filter at Guardian level**: Within Bash results, only test/build/git outputs trigger LLM analysis. Short commands (ls, cat, etc.) are accumulated as context but don't trigger LLM calls.
3. **Batch processing**: The Guardian accumulates PostToolUse events and only calls the LLM when a significant event occurs (Stop, Notification, or a matching PostToolUse pattern).
4. **Context vs. trigger**: Most PostToolUse events are added to the Guardian's context window (cheap, no LLM call) but only a few trigger actual notification generation (expensive, LLM call).

```
PostToolUse events:
    ├── "npm test" result     → trigger LLM (test result = important)
    ├── "swift build" output  → trigger LLM (build result = important)
    ├── "git commit" output   → trigger LLM (git operation = important)
    ├── "ls -la" output       → context only (no LLM call)
    ├── "cat file.ts" output  → context only (no LLM call)
    └── "echo hello" output   → discard (noise)
```

### In Scope (Phase 2)

- Guardian TS/Bun process with AI loop
- OpenAI-compatible LLM integration (custom base URL + model)
- Context maintenance across messages with auto-compression
- Notification rewriting (title, body, subtitle inference)
- Deduplication and suppression of redundant notifications
- CLI `--hook` flag for forwarding raw Claude Code hook payloads
- Hook-aware wire format (`_hook` field) for daemon ↔ Guardian
- PostToolUse batching and filtering strategy
- Settings UI (API key, base URL, model, guardian toggle)
- Keychain storage for API key
- Daemon ↔ Guardian JSON-RPC protocol
- Process lifecycle management (spawn, restart, shutdown)
- Graceful fallback to raw delivery on any AI failure
- Example Claude Code hook configuration in docs

### Out of Scope (Future)

- Notification replacement (update existing notification by stable ID)
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

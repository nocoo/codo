# 03 - AI Guardian: Detailed Design

> Atomic commits, data structures, module layout, and four-layer test plan for the AI Guardian feature defined in [02-ai-guardian.md](02-ai-guardian.md).

## Module Layout

### New Swift Modules

| File | Purpose |
|------|---------|
| `Sources/CodoCore/HookEvent.swift` | `HookEvent` struct (discriminated union counterpart to `CodoMessage`) |
| `Sources/CodoCore/MessageRouter.swift` | Decode raw JSON, dispatch `CodoMessage` vs `HookEvent` |
| `Sources/CodoCore/GuardianProcess.swift` | Spawn/restart/kill TS child process, stdin/stdout JSON-RPC pipe |
| `Sources/CodoCore/GuardianProtocol.swift` | `GuardianProvider` protocol + JSON-RPC message types |
| `Sources/CodoCore/KeychainService.swift` | Read/write API key via Security.framework |
| `Sources/CodoCore/SettingsStore.swift` | UserDefaults wrapper for Guardian settings |
| `Sources/Codo/SettingsWindow.swift` | NSWindow + NSViewController for settings panel |
| `Sources/Codo/AppDelegate.swift` | Extended: Guardian lifecycle, menu items, settings trigger |

### New TypeScript Modules

| File | Purpose |
|------|---------|
| `guardian/main.ts` | Entry point — stdin reader, JSON-RPC dispatch, event loop |
| `guardian/state.ts` | Three-layer state model (WorkingStateStore, EventBuffer, SummarySnapshot) |
| `guardian/llm.ts` | OpenAI-compatible client wrapper, tool definitions, prompt assembly |
| `guardian/classifier.ts` | Event classification (important / contextual / noise) |
| `guardian/fallback.ts` | Guardian OFF / LLM failure fallback mapping |
| `guardian/types.ts` | Shared TypeScript types (HookEvent, GuardianConfig, JsonRpc) |
| `guardian/package.json` | Dependencies: `openai`, `js-tiktoken` |
| `guardian/biome.json` | Linter config (consistent with `cli/biome.json`) |
| `guardian/tsconfig.json` | TypeScript config |

### CLI Extension

| File | Changes |
|------|---------|
| `cli/codo.ts` | Add `--hook <type>` flag, forward raw stdin JSON with `_hook` discriminator |

### Updated Files

| File | Changes |
|------|---------|
| `Sources/CodoCore/SocketServer.swift` | Replace `MessageHandler = (CodoMessage) -> CodoResponse` with `RawMessageHandler = (Data) -> CodoResponse` |
| `Sources/CodoTestServer/CodoTestServer.swift` | Handle both `CodoMessage` and `HookEvent` in log output |
| `Package.swift` | No new targets — Guardian is TS/Bun, not Swift |

---

## Data Structures

### Swift Side

#### `HookEvent`

```swift
// Sources/CodoCore/HookEvent.swift

/// Raw hook event from Claude Code, forwarded via CLI --hook flag.
/// The `_hook` field is the discriminator that distinguishes this from CodoMessage.
public struct HookEvent: Codable, Sendable {
    /// Hook type: "stop", "notification", "post-tool-use",
    /// "post-tool-use-failure", "session-start", "session-end"
    public let hook: String

    /// Raw JSON payload from Claude Code (preserved as-is for Guardian).
    /// Contains session_id, cwd, transcript_path, and event-specific fields.
    public let payload: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case hook = "_hook"
        case payload // virtual — everything except _hook
    }
}
```

**`AnyCodable`**: A lightweight `Codable` wrapper for `Any` — only needs to round-trip JSON. The daemon does not inspect payload fields; it forwards the entire JSON blob to the Guardian. We can use a simpler approach: the daemon decodes raw JSON as `[String: Any]`, extracts `_hook`, and forwards the original JSON bytes to the Guardian without re-encoding.

#### `MessageRouter`

```swift
// Sources/CodoCore/MessageRouter.swift

/// Result of routing a raw JSON message.
public enum RoutedMessage: Sendable {
    case notification(CodoMessage)
    case hookEvent(hook: String, rawJSON: Data)
}

/// Routes raw JSON to either CodoMessage or HookEvent path.
public enum MessageRouter {
    public static func route(_ data: Data) throws -> RoutedMessage {
        // Peek at JSON for "_hook" field
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let obj else { throw MessageRouterError.invalidJSON }

        if let hook = obj["_hook"] as? String {
            return .hookEvent(hook: hook, rawJSON: data)
        } else {
            let message = try JSONDecoder().decode(CodoMessage.self, from: data)
            return .notification(message)
        }
    }
}
```

#### `GuardianProvider` Protocol

```swift
// Sources/CodoCore/GuardianProtocol.swift

/// JSON-RPC message to send to Guardian process via stdin.
public struct GuardianRequest: Codable, Sendable {
    public let jsonrpc: String  // "2.0"
    public let id: Int
    public let method: String   // "process_message" or "process_hook"
    public let params: [String: AnyCodable]
}

/// JSON-RPC response from Guardian process via stdout.
public struct GuardianResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int
    public let result: GuardianResult
}

public struct GuardianResult: Codable, Sendable {
    public let action: String  // "send" or "suppress"
    public let notification: CodoMessage?  // present when action == "send"
    public let reason: String?             // present when action == "suppress"
}

/// Protocol for Guardian communication, enabling testability.
public protocol GuardianProvider: Sendable {
    var isAlive: Bool { get }
    func send(hookEvent rawJSON: Data) async throws
    func send(message: CodoMessage) async throws
    func start() throws
    func stop()
}
```

#### `GuardianProcess`

```swift
// Sources/CodoCore/GuardianProcess.swift

/// Manages the Guardian child process lifecycle.
/// Communicates via stdin (daemon→guardian) and stdout (guardian→daemon).
public final class GuardianProcess: GuardianProvider, @unchecked Sendable {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var requestId: Int = 0
    private let notificationService: NotificationService
    private let guardianPath: String  // path to guardian/main.ts
    private let config: GuardianConfig
    private var restartCount: Int = 0
    private let maxRestarts = 3

    // stdout reader pumps responses and calls NotificationService
    // when action == "send"
}
```

#### `KeychainService`

```swift
// Sources/CodoCore/KeychainService.swift

/// Reads and writes the API key from macOS Keychain.
public enum KeychainService {
    private static let service = "ai.hexly.codo.01"
    private static let account = "guardian-api-key"

    public static func readAPIKey() -> String? { ... }
    public static func writeAPIKey(_ key: String) throws { ... }
    public static func deleteAPIKey() throws { ... }
}
```

#### `SettingsStore`

```swift
// Sources/CodoCore/SettingsStore.swift

/// UserDefaults-backed settings for Guardian configuration.
public final class SettingsStore: ObservableObject, Sendable {
    public static let shared = SettingsStore()

    // Keys
    private enum Key: String {
        case guardianEnabled  = "guardianEnabled"
        case baseURL          = "guardianBaseURL"
        case model            = "guardianModel"
        case contextLimit     = "guardianContextLimit"
    }

    public var guardianEnabled: Bool    // default: false
    public var baseURL: String          // default: "https://api.openai.com/v1"
    public var model: String            // default: "gpt-4o-mini"
    public var contextLimit: Int        // default: 160000
}
```

### TypeScript Side

#### `guardian/types.ts`

```typescript
// JSON-RPC types
export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number;
  method: "process_message" | "process_hook";
  params: Record<string, unknown>;
}

export interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number;
  result: GuardianResult;
}

export interface GuardianResult {
  action: "send" | "suppress";
  notification?: NotificationPayload;
  reason?: string;
}

export interface NotificationPayload {
  title: string;
  body?: string;
  subtitle?: string;
  sound?: string;
  threadId?: string;
}

// Hook event types
export type HookEventName =
  | "stop"
  | "notification"
  | "post-tool-use"
  | "post-tool-use-failure"
  | "session-start"
  | "session-end";

export interface HookEvent {
  _hook: HookEventName;
  session_id: string;
  cwd: string;
  transcript_path?: string;
  hook_event_name: string;
  [key: string]: unknown;  // event-specific fields
}

// Guardian config (passed via env or stdin on startup)
export interface GuardianConfig {
  apiKey: string;
  baseURL: string;
  model: string;
  contextLimit: number;
}
```

#### `guardian/state.ts`

```typescript
// Three-layer state model

export interface ProjectState {
  cwd: string;               // canonical path (realpath)
  sessionId: string | null;
  task: string | null;        // current task description
  lastStatus: string | null;  // last significant result
  model: string | null;
  recentNotifications: Array<{ title: string; time: number }>;
  lastEventTime: number;      // for eviction
  sessionActive: boolean;
  transcriptLastReadOffset: number;
}

export interface BufferedEvent {
  timestamp: number;
  hookType: HookEventName;
  sessionId: string;
  cwd: string;
  summary: string;    // terse one-line summary for LLM context
  raw: Record<string, unknown>;  // full payload
}

export interface StateStore {
  // Layer 1: Working State Store
  projects: Map<string, ProjectState>;  // key = canonical cwd

  // Layer 2: Recent Event Buffer (rolling FIFO, max ~50)
  events: BufferedEvent[];

  // Layer 3: Summary Snapshot (LLM-compressed)
  summary: string;
}

// Operations
export function updateState(store: StateStore, event: HookEvent): void;
export function evictStaleProjects(store: StateStore, maxAgeMs: number): void;
export function serializeForPrompt(store: StateStore, maxEvents: number): string;
export function getProject(store: StateStore, cwd: string): ProjectState | undefined;
export function canonicalizePath(cwd: string): string;  // realpath wrapper
```

#### `guardian/classifier.ts`

```typescript
export type EventTier = "important" | "contextual" | "noise";

/** Classify a PostToolUse event by command pattern. */
export function classifyBashEvent(
  command: string,
  output: string,
): EventTier;

/** Classify any hook event for processing. */
export function classifyEvent(event: HookEvent): {
  tier: EventTier;
  shouldTriggerLLM: boolean;
};
```

#### `guardian/llm.ts`

```typescript
import OpenAI from "openai";

export interface LLMClient {
  process(event: HookEvent, state: StateStore): Promise<GuardianResult>;
}

export function createLLMClient(config: GuardianConfig): LLMClient;

// Prompt assembly
export function buildSystemPrompt(state: StateStore): string;
export function buildUserMessage(event: HookEvent): string;

// Tool definitions for the LLM
export const TOOLS: OpenAI.Chat.Completions.ChatCompletionTool[];
```

#### `guardian/fallback.ts`

```typescript
/** Generate a raw notification when Guardian is OFF or LLM fails. */
export function fallbackNotification(
  event: HookEvent,
): NotificationPayload | null;  // null = suppress
```

---

## SocketServer Refactor: Raw Handler

The current `SocketServer` decodes JSON into `CodoMessage` internally. For the discriminated union to work, the server must hand **raw bytes** to the handler so `MessageRouter` can inspect `_hook` first.

### Before

```swift
public typealias MessageHandler = @Sendable (CodoMessage) -> CodoResponse
// SocketServer decodes JSON → CodoMessage → calls handler
```

### After

```swift
public typealias RawMessageHandler = @Sendable (Data) -> CodoResponse
// SocketServer passes raw Data → handler routes via MessageRouter
```

The `MessageHandler` typedef is preserved as a convenience alias for callers who don't need raw routing (e.g., `CodoTestServer`). A new `init(socketPath:rawHandler:)` initializer accepts `RawMessageHandler`.

**Migration**: `AppDelegate` switches to `rawHandler` and uses `MessageRouter` internally. `CodoTestServer` continues using the existing `MessageHandler` convenience.

---

## Atomic Commits

Each commit is independently testable. Tests are written **before or alongside** the implementation (TDD).

| # | Type | Message | Files Changed | Tests Added |
|---|------|---------|---------------|-------------|
| 1 | `docs` | `docs: add AI Guardian detailed design` | `docs/features/03-ai-guardian-detail.md`, `docs/features/README.md` | — |
| 2 | `feat` | `feat: add HookEvent and MessageRouter` | `Sources/CodoCore/HookEvent.swift`, `Sources/CodoCore/MessageRouter.swift` | `Tests/CodoCoreTests/MessageRouterTests.swift` |
| 3 | `refactor` | `refactor: add raw handler to SocketServer` | `Sources/CodoCore/SocketServer.swift` | `Tests/CodoCoreTests/SocketTests.swift` (update) |
| 4 | `feat` | `feat: add --hook flag to CLI` | `cli/codo.ts` | `cli/codo.test.ts` (new hook tests) |
| 5 | `test` | `test: add hook event integration tests` | `Sources/CodoTestServer/CodoTestServer.swift`, `scripts/integration-test.sh` | L3: hook event roundtrip |
| 6 | `feat` | `feat: add KeychainService and SettingsStore` | `Sources/CodoCore/KeychainService.swift`, `Sources/CodoCore/SettingsStore.swift` | `Tests/CodoCoreTests/SettingsStoreTests.swift` |
| 7 | `feat` | `feat: add GuardianProtocol and GuardianProcess` | `Sources/CodoCore/GuardianProtocol.swift`, `Sources/CodoCore/GuardianProcess.swift` | `Tests/CodoCoreTests/GuardianProcessTests.swift` |
| 8 | `feat` | `feat: add settings window UI` | `Sources/Codo/SettingsWindow.swift` | L4: manual visual check |
| 9 | `refactor` | `refactor: wire MessageRouter and Guardian into AppDelegate` | `Sources/Codo/AppDelegate.swift` | `Tests/CodoCoreTests/MessageRouterTests.swift` (integration) |
| 10 | `feat` | `feat: add Guardian state module` | `guardian/types.ts`, `guardian/state.ts` | `guardian/state.test.ts` |
| 11 | `feat` | `feat: add event classifier` | `guardian/classifier.ts` | `guardian/classifier.test.ts` |
| 12 | `feat` | `feat: add fallback notification mapping` | `guardian/fallback.ts` | `guardian/fallback.test.ts` |
| 13 | `feat` | `feat: add LLM client and prompt assembly` | `guardian/llm.ts` | `guardian/llm.test.ts` |
| 14 | `feat` | `feat: add Guardian main entry point` | `guardian/main.ts`, `guardian/package.json`, `guardian/biome.json` | `guardian/main.test.ts` |
| 15 | `test` | `test: add Guardian integration tests` | `scripts/integration-test.sh` | L3: full Guardian roundtrip |
| 16 | `test` | `test: update L4 E2E checklist for Guardian` | `scripts/e2e-test.sh` | L4: Guardian visual checks |
| 17 | `docs` | `docs: update architecture docs and README` | `docs/architecture/*.md`, `README.md` | — |

### Commit Detail

#### Commit 2: `feat: add HookEvent and MessageRouter`

Create the discriminated union types and routing logic.

**`Sources/CodoCore/HookEvent.swift`**:
- `HookEvent` struct with `_hook` field
- Minimal — daemon only reads `_hook` and forwards raw bytes

**`Sources/CodoCore/MessageRouter.swift`**:
- `RoutedMessage` enum: `.notification(CodoMessage)` | `.hookEvent(hook:rawJSON:)`
- `MessageRouter.route(_ data: Data)` — peek JSON for `_hook`, branch accordingly
- `MessageRouterError` — `invalidJSON`, `missingTitle`

**Tests** (`Tests/CodoCoreTests/MessageRouterTests.swift`):
| Test | Input | Expected |
|------|-------|----------|
| route CodoMessage | `{"title":"T"}` | `.notification(CodoMessage)` |
| route CodoMessage with all fields | `{"title":"T","subtitle":"S","threadId":"t"}` | `.notification(...)` with all fields |
| route HookEvent stop | `{"_hook":"stop","session_id":"s1","cwd":"/tmp"}` | `.hookEvent(hook:"stop", rawJSON: ...)` |
| route HookEvent notification | `{"_hook":"notification","title":"P"}` | `.hookEvent(hook:"notification", ...)` |
| route invalid JSON | `"not json"` | throws `invalidJSON` |
| route empty object | `{}` | throws (no title, no _hook → CodoMessage decode fails) |
| route CodoMessage missing title | `{"body":"B"}` | throws `missingTitle` |
| hook event preserves raw JSON | `{"_hook":"stop","custom":123}` | rawJSON contains original bytes |

#### Commit 3: `refactor: add raw handler to SocketServer`

**`Sources/CodoCore/SocketServer.swift`**:
- Add `RawMessageHandler = @Sendable (Data) -> CodoResponse`
- Add `init(socketPath:rawHandler:)` — stores `rawHandler`
- Existing `init(socketPath:handler:)` wraps the `MessageHandler` in a `RawMessageHandler` that decodes internally (backward compat)
- `handleClient()` now passes raw `Data` to the stored handler (either raw or wrapped)

**Tests**: Update existing `SocketTests.swift` to verify both init paths work. Add:
| Test | Scenario | Expected |
|------|----------|----------|
| raw handler receives data | send JSON bytes | raw handler called with Data |
| raw handler for hook event | send `{"_hook":"stop"}` | handler receives bytes, can decode `_hook` |
| legacy handler still works | existing tests unchanged | all pass |

#### Commit 4: `feat: add --hook flag to CLI`

**`cli/codo.ts`**:
- New `--hook <type>` value flag in `parseArgs()`
- When `--hook` is present: read stdin as raw JSON, inject `"_hook": <type>` field, send to daemon
- Returns `CodoMessage` variant when `--hook` absent (existing behavior)
- New exported function: `parseHook(hookType: string, stdinJSON: string): object | { error: string }`

**Tests** (`cli/codo.test.ts`):
| Test | Input | Expected |
|------|-------|----------|
| `--hook stop` with valid stdin | args: `["--hook", "stop"]`, stdin: `{"session_id":"s1"}` | sends `{"_hook":"stop","session_id":"s1"}` |
| `--hook notification` | valid stdin | sends with `_hook: "notification"` |
| `--hook` without value | `["--hook"]` | error: `--hook requires a value` |
| `--hook` with unknown type | `["--hook", "bogus"]` | error: `unknown hook type: bogus` |
| `--hook` conflicts with title arg | `["Title", "--hook", "stop"]` | error: `--hook cannot be used with positional args` |
| `--hook` forwards all stdin fields | stdin has `session_id`, `cwd`, `tool_name` etc. | all fields preserved in output |
| `--hook` with empty stdin | `["--hook", "stop"]`, stdin: `` | error: `empty input` |
| `--hook` with invalid stdin JSON | `["--hook", "stop"]`, stdin: `{bad` | error: `invalid json` |
| `parseHook` injects _hook field | `"stop"`, `{"session_id":"s1"}` | `{"_hook":"stop","session_id":"s1"}` |

#### Commit 5: `test: add hook event integration tests`

**`Sources/CodoTestServer/CodoTestServer.swift`**:
- Switch from `MessageHandler` to `RawMessageHandler`
- Use `MessageRouter.route()` to decode
- Log both `CodoMessage` and `HookEvent` to `messages.log`
- For `HookEvent`: log `{"_hook":"stop","session_id":"...","cwd":"..."}` (raw payload)
- For `CodoMessage`: log as before

**`scripts/integration-test.sh`** — new section `--- Hook events ---`:
| Test | Scenario | Expected |
|------|----------|----------|
| `--hook stop` roundtrip | pipe JSON to CLI with `--hook stop` | server log shows `_hook: "stop"` |
| `--hook notification` roundtrip | pipe notification JSON | server log shows `_hook: "notification"` |
| `--hook post-tool-use` roundtrip | pipe PostToolUse JSON | server log shows tool data |
| hook preserves all fields | stdin with `session_id`, `cwd`, `tool_name` etc. | all fields in server log |
| existing CodoMessage unaffected | same old tests | all still pass |

#### Commit 6: `feat: add KeychainService and SettingsStore`

**`Sources/CodoCore/KeychainService.swift`**:
- `readAPIKey()`, `writeAPIKey(_:)`, `deleteAPIKey()` using Security.framework
- Uses `kSecClassGenericPassword` with service `"ai.hexly.codo.01"` and account `"guardian-api-key"`

**`Sources/CodoCore/SettingsStore.swift`**:
- UserDefaults wrapper with `guardianEnabled`, `baseURL`, `model`, `contextLimit`
- `toGuardianConfig() -> [String: Any]` for serializing to Guardian process env

**Tests** (`Tests/CodoCoreTests/SettingsStoreTests.swift`):
| Test | Scenario | Expected |
|------|----------|----------|
| default values | fresh store | enabled=false, baseURL=openai, model=gpt-4o-mini, contextLimit=160000 |
| read/write guardianEnabled | toggle on/off | persists and reads back |
| read/write baseURL | custom URL | persists |
| read/write model | custom model | persists |
| toGuardianConfig | all settings | dict with all keys |

**Note**: `KeychainService` unit tests are difficult because they require a real Keychain. Tests use a mock wrapper or skip Keychain in CI — tested manually in L4.

#### Commit 7: `feat: add GuardianProtocol and GuardianProcess`

**`Sources/CodoCore/GuardianProtocol.swift`**:
- `GuardianProvider` protocol (see data structures above)
- JSON-RPC request/response types
- `MockGuardianProvider` for testing

**`Sources/CodoCore/GuardianProcess.swift`**:
- `GuardianProcess` — spawns `bun guardian/main.ts` as child process
- Stdin pipe for sending requests, stdout pipe for reading responses
- Restart logic (max 3, then disable)
- SIGTERM on stop

**Tests** (`Tests/CodoCoreTests/GuardianProcessTests.swift`):
| Test | Scenario | Expected |
|------|----------|----------|
| mock provider send message | send CodoMessage to mock | mock receives it |
| mock provider send hook | send hook data to mock | mock receives it |
| mock provider isAlive | after start | true |
| mock provider stop | after stop | isAlive = false |
| restart count exceeded | 3 failures | isAlive = false, disabled |

**Note**: Real process spawn tests are L3/L4 (require `bun` runtime + built Guardian). Unit tests use `MockGuardianProvider`.

#### Commit 8: `feat: add settings window UI`

**`Sources/Codo/SettingsWindow.swift`**:
- `SettingsWindowController` (NSWindowController)
- NSTextField for Base URL, Model
- NSSecureTextField for API Key (reads/writes via KeychainService)
- NSSwitch for Guardian Enabled
- NSTextField (number) for Context Limit
- Save button commits to SettingsStore + Keychain
- Cancel button dismisses

No automated tests — UI is L4 manual verification.

#### Commit 9: `refactor: wire MessageRouter and Guardian into AppDelegate`

**`Sources/Codo/AppDelegate.swift`**:
- Replace `SocketServer(handler:)` with `SocketServer(rawHandler:)`
- Raw handler calls `MessageRouter.route()`
- `.notification(msg)` → existing `NotificationService` path
- `.hookEvent(hook, rawJSON)` → check `SettingsStore.guardianEnabled`:
  - ON: forward to `GuardianProcess`
  - OFF: use `fallbackNotification()` and deliver raw
- Menu: add "AI Guardian" toggle item, "Settings..." item
- On toggle: spawn or kill Guardian process
- On startup: if `guardianEnabled` && API key present → spawn Guardian

**Tests**: Update `MessageRouterTests.swift` with:
| Test | Scenario | Expected |
|------|----------|----------|
| AppDelegate routes CodoMessage | send `{"title":"T"}` | NotificationService receives it |
| AppDelegate routes HookEvent, guardian ON | send `{"_hook":"stop",...}` | GuardianProvider receives it |
| AppDelegate routes HookEvent, guardian OFF | send `{"_hook":"stop",...}` | fallback notification delivered |

These are tested via mock providers wired into the router, not real AppDelegate.

#### Commits 10-14: Guardian TypeScript Modules

Each module is a self-contained unit with its own test file. All tests run via `cd guardian && bun test`.

**Commit 10: `feat: add Guardian state module`**

`guardian/state.ts` + `guardian/state.test.ts`:
| Test | Scenario | Expected |
|------|----------|----------|
| canonicalizePath | symlink / relative | resolved path |
| getProject new | unknown cwd | undefined |
| updateState SessionStart | new session | project created with session_id, model |
| updateState PostToolUse important | npm test result | project.lastStatus updated, event in buffer |
| updateState PostToolUse contextual | ls command | event in buffer, project unchanged |
| updateState PostToolUse noise | echo hello | no state change |
| updateState Stop | with last_assistant_message | project.task updated |
| updateState Stop generic | "done" message, existing specific task | task NOT overwritten |
| updateState Notification | notification event | recorded in recentNotifications |
| updateState SessionEnd | end session | sessionActive = false |
| evictStaleProjects | project inactive > 24h | evicted from Layer 1 |
| evictStaleProjects | project inactive < 24h | kept |
| serializeForPrompt | two projects, 10 events | formatted string with projects + events |
| event buffer FIFO | push > 50 events | oldest dropped, size stays ≤ 50 |
| event buffer preserves order | sequential events | FIFO order |

**Commit 11: `feat: add event classifier`**

`guardian/classifier.ts` + `guardian/classifier.test.ts`:
| Test | Scenario | Expected |
|------|----------|----------|
| classifyBashEvent npm test | `"npm test"` | `"important"` |
| classifyBashEvent swift build | `"swift build"` | `"important"` |
| classifyBashEvent swift test | `"swift test"` | `"important"` |
| classifyBashEvent git commit | `"git commit -m ..."` | `"important"` |
| classifyBashEvent git push | `"git push"` | `"important"` |
| classifyBashEvent bun test | `"bun test"` | `"important"` |
| classifyBashEvent ls | `"ls -la"` | `"contextual"` |
| classifyBashEvent cat | `"cat file.ts"` | `"contextual"` |
| classifyBashEvent grep | `"grep pattern"` | `"contextual"` |
| classifyBashEvent echo | `"echo hello"` | `"noise"` |
| classifyBashEvent pwd | `"pwd"` | `"noise"` |
| classifyBashEvent short output | output < 10 chars | `"noise"` |
| classifyEvent Stop | Stop hook | `{ tier: "important", shouldTriggerLLM: true }` |
| classifyEvent Notification | Notification hook | `{ tier: "important", shouldTriggerLLM: true }` |
| classifyEvent PostToolUseFailure | failure hook | `{ tier: "important", shouldTriggerLLM: true }` |
| classifyEvent SessionStart | session start | `{ tier: "contextual", shouldTriggerLLM: false }` |
| classifyEvent SessionEnd | session end | `{ tier: "contextual", shouldTriggerLLM: false }` |
| classifyEvent PostToolUse important | npm test | `{ tier: "important", shouldTriggerLLM: true }` |
| classifyEvent PostToolUse contextual | ls | `{ tier: "contextual", shouldTriggerLLM: false }` |

**Commit 12: `feat: add fallback notification mapping`**

`guardian/fallback.ts` + `guardian/fallback.test.ts`:
| Test | Scenario | Expected |
|------|----------|----------|
| fallback Notification | `{_hook:"notification", title:"T", message:"M"}` | `{title:"T", body:"M"}` |
| fallback Notification no title | `{_hook:"notification", message:"M"}` | `{title:"Codo", body:"M"}` |
| fallback Stop | `{_hook:"stop", last_assistant_message:"Did X"}` | `{title:"Task Complete", body:"Did X"...}` |
| fallback Stop long message | message > 100 chars | body truncated to 100 chars |
| fallback PostToolUse test | `{tool_name:"Bash", command:"npm test", tool_response:"42 passed"}` | `{title:"Bash result", body:"42 passed"}` |
| fallback PostToolUse noise | `{tool_name:"Bash", command:"ls"}` | `null` (suppressed) |
| fallback PostToolUseFailure | `{error:"Command failed..."}` | `{title:"Bash failed", body:"Command failed..."}` |
| fallback SessionStart | `{model:"claude-sonnet-4-6"}` | `{title:"Session Started", body:"claude-sonnet-4-6"}` |
| fallback SessionEnd | any | `null` (suppressed) |

**Commit 13: `feat: add LLM client and prompt assembly`**

`guardian/llm.ts` + `guardian/llm.test.ts`:
| Test | Scenario | Expected |
|------|----------|----------|
| buildSystemPrompt | state with 2 projects, 5 events | contains role, tools, project summaries, events |
| buildSystemPrompt empty state | no projects, no events | contains role + tools only |
| buildUserMessage Stop | stop event | contains `last_assistant_message` |
| buildUserMessage Notification | notification event | contains `title`, `message`, `notification_type` |
| buildUserMessage PostToolUse | tool use event | contains `tool_name`, `command`, `tool_response` |
| TOOLS definition | tool list | contains `send_notification` and `suppress` |
| createLLMClient | config | returns client with correct base URL and model |
| process with mock OpenAI | mock returns send action | returns notification payload |
| process with mock OpenAI | mock returns suppress | returns suppress with reason |
| process timeout | mock times out > 10s | falls back to raw notification |
| process API error | mock returns 500 | falls back to raw notification |

**Note**: LLM tests use a mock OpenAI client (inject via `createLLMClient` accepting a client instance). No real API calls in L1.

**Commit 14: `feat: add Guardian main entry point`**

`guardian/main.ts` + `guardian/main.test.ts`:
| Test | Scenario | Expected |
|------|----------|----------|
| stdin parse | JSON-RPC line on stdin | parsed as request |
| stdout response | send action | JSON-RPC response on stdout |
| process_hook method | hook event | classified, state updated, LLM called if needed |
| process_message method | CodoMessage | processed as direct notification |
| unknown method | bad method name | error response |
| malformed JSON-RPC | invalid JSON | error response |
| sequential requests | 3 requests in sequence | all processed, state accumulated |

---

## Four-Layer Test Plan

### L1 — Unit Tests

**Swift** (`swift test`): Existing 46 tests + new tests below.

| File | New Tests | Count |
|------|-----------|-------|
| `Tests/CodoCoreTests/MessageRouterTests.swift` | Route CodoMessage, route HookEvent, invalid JSON, missing title, preserve raw bytes | ~8 |
| `Tests/CodoCoreTests/SocketTests.swift` | Raw handler init, raw handler receives data, legacy handler compat | ~3 |
| `Tests/CodoCoreTests/SettingsStoreTests.swift` | Default values, read/write each setting, toGuardianConfig | ~5 |
| `Tests/CodoCoreTests/GuardianProcessTests.swift` | Mock provider: send message, send hook, isAlive, stop, restart exceeded | ~5 |
| **Subtotal** | | **~21 new** |

**TypeScript CLI** (`cd cli && bun test`): Existing 60 tests + new tests.

| File | New Tests | Count |
|------|-----------|-------|
| `cli/codo.test.ts` | --hook flag parsing, parseHook, --hook conflicts | ~9 |
| **Subtotal** | | **~9 new** |

**TypeScript Guardian** (`cd guardian && bun test`): All new.

| File | Tests | Count |
|------|-------|-------|
| `guardian/state.test.ts` | State operations, canonicalize, eviction, buffer FIFO, serialize | ~15 |
| `guardian/classifier.test.ts` | Bash classification, event classification | ~18 |
| `guardian/fallback.test.ts` | Fallback per hook type, truncation, suppression | ~9 |
| `guardian/llm.test.ts` | Prompt assembly, tool defs, mock LLM process, timeout, error | ~11 |
| `guardian/main.test.ts` | stdin/stdout, method dispatch, state accumulation | ~7 |
| **Subtotal** | | **~60 new** |

**Estimated totals after Guardian**:
- Swift: ~67 tests (46 + 21)
- TS CLI: ~69 tests (60 + 9)
- TS Guardian: ~60 tests
- **Total L1: ~196 tests**

### L2 — Lint

**Swift**: SwiftLint strict (existing). New files automatically covered.

**TypeScript CLI**: Biome (existing).

**TypeScript Guardian**: New `guardian/biome.json` — same rules as `cli/biome.json`.

**Lint commands** (updated for `guardian/`):
```bash
# Swift
swiftlint lint --strict --quiet

# TS (both cli and guardian)
cd cli && bunx biome check . && cd ..
cd guardian && bunx biome check . && cd ..
```

### L3 — Integration Tests

`scripts/integration-test.sh` — extended with new sections.

**New tests**:

| Section | Test | Scenario | Expected |
|---------|------|----------|----------|
| Hook events | `--hook stop` roundtrip | pipe stop JSON via CLI | server log shows `_hook: "stop"` with all fields |
| Hook events | `--hook notification` roundtrip | pipe notification JSON | server log shows `_hook: "notification"` |
| Hook events | `--hook post-tool-use` roundtrip | pipe PostToolUse JSON | server log shows tool data |
| Hook events | hook preserves fields | stdin with many fields | all fields in server log |
| Hook events | `--hook` unknown type | `--hook bogus` | exit 1, error message |
| Hook events | `--hook` with title arg | `"Title" --hook stop` | exit 1, conflict error |
| Guardian roundtrip | Guardian OFF fallback | send hook, no Guardian | raw notification in server log |
| Guardian roundtrip | Guardian ON (mock) | send hook to mock Guardian | Guardian-processed notification in server log |

**Note**: Full Guardian roundtrip with real LLM is not testable in L3 (requires API key). L3 tests the plumbing (CLI → daemon → Guardian process spawn → stdin/stdout → notification delivery) using a mock Guardian script that echoes back a fixed response.

**Mock Guardian for L3**: A minimal Bun script (`scripts/mock-guardian.ts`) that reads JSON-RPC from stdin, returns a fixed `send` response. The test server spawns this instead of the real Guardian.

### L4 — E2E Manual Checklist

`scripts/e2e-test.sh` — extended with Guardian section.

```markdown
## Pre-release E2E Checklist (Guardian)

### Settings UI
- [ ] Click "Settings..." in menubar → window opens
- [ ] API Key field is a secure field (masked)
- [ ] Enter API key → save → re-open → key persists (Keychain)
- [ ] Enter custom Base URL → save → persists
- [ ] Change model name → save → persists
- [ ] Toggle "AI Guardian" ON → Guardian process spawns (check `ps aux | grep guardian`)
- [ ] Toggle "AI Guardian" OFF → Guardian process stops

### Guardian ON (requires API key)
- [ ] `echo '{"_hook":"stop","session_id":"s1","cwd":"/tmp","last_assistant_message":"Refactored auth module, 42 tests pass"}' | codo --hook stop`
  → AI-rewritten notification appears (not raw text)
- [ ] `echo '{"_hook":"notification","session_id":"s1","cwd":"/tmp","title":"Permission needed","message":"Approve Bash?","notification_type":"permission_prompt"}' | codo --hook notification`
  → Notification with enriched context
- [ ] Send 3 similar build-failed hooks → at least 1 suppressed (dedup)
- [ ] Send stop hook with long message → notification is concise (not 1:1 copy)

### Guardian OFF (no API key)
- [ ] Remove API key from settings
- [ ] `echo '{"_hook":"stop","session_id":"s1","cwd":"/tmp","last_assistant_message":"Done"}' | codo --hook stop`
  → Raw notification: "Task Complete — Done"
- [ ] `echo '{"_hook":"notification","session_id":"s1","cwd":"/tmp","title":"Perm","message":"Approve?"}' | codo --hook notification`
  → Raw notification: "Perm — Approve?"
- [ ] `echo '{"_hook":"session-end","session_id":"s1"}' | codo --hook session-end`
  → No notification (suppressed)

### Guardian Resilience
- [ ] Kill Guardian process → send hook → raw fallback notification + Guardian restarts
- [ ] Kill Guardian 3 times → Guardian stays dead, menubar shows Guardian OFF
- [ ] Restart daemon → Guardian auto-spawns if enabled + API key present

### Existing Features (regression)
- [ ] `codo "Hello"` → notification (unchanged)
- [ ] `codo "Build Done" --template success` → ✅ Success subtitle (unchanged)
- [ ] `codo --template list` → template table (unchanged)
- [ ] `echo '{"title":"Test"}' | codo` → notification (unchanged)
```

### Git Hooks (Updated)

**pre-commit**:
```bash
#!/bin/bash
set -euo pipefail

# L2: Lint
swiftlint lint --strict --quiet
cd cli && bunx biome check . && cd ..
cd guardian && bunx biome check . && cd ..

# L1: Unit tests
swift test
cd cli && bun test && cd ..
cd guardian && bun test && cd ..
```

**pre-push**:
```bash
#!/bin/bash
set -euo pipefail

# L1 + L2
swiftlint lint --strict --quiet
swift test
cd cli && bunx biome check . && bun test && cd ..
cd guardian && bunx biome check . && bun test && cd ..

# L3: Integration
./scripts/integration-test.sh
```

---

## Verification Commands

```bash
# L1: Swift unit tests
swift test

# L1: TS CLI unit tests
cd cli && bun test

# L1: TS Guardian unit tests
cd guardian && bun test

# L2: Swift lint
swiftlint lint --strict --quiet

# L2: TS lint (both modules)
cd cli && bunx biome check . && cd ..
cd guardian && bunx biome check . && cd ..

# L3: Integration
bash scripts/integration-test.sh

# L4: Manual
bash scripts/build.sh && open .build/release/Codo.app
bash scripts/e2e-test.sh

# Full regression (what pre-push runs)
swift test && cd cli && bun test && cd .. && cd guardian && bun test && cd .. \
  && swiftlint lint --strict --quiet \
  && cd cli && bunx biome check . && cd .. \
  && cd guardian && bunx biome check . && cd .. \
  && bash scripts/integration-test.sh
```

## Status

| # | Commit | Status |
|---|--------|--------|
| 1 | `docs: add AI Guardian detailed design` | |
| 2 | `feat: add HookEvent and MessageRouter` | |
| 3 | `refactor: add raw handler to SocketServer` | |
| 4 | `feat: add --hook flag to CLI` | |
| 5 | `test: add hook event integration tests` | |
| 6 | `feat: add KeychainService and SettingsStore` | |
| 7 | `feat: add GuardianProtocol and GuardianProcess` | |
| 8 | `feat: add settings window UI` | |
| 9 | `refactor: wire MessageRouter and Guardian into AppDelegate` | |
| 10 | `feat: add Guardian state module` | |
| 11 | `feat: add event classifier` | |
| 12 | `feat: add fallback notification mapping` | |
| 13 | `feat: add LLM client and prompt assembly` | |
| 14 | `feat: add Guardian main entry point` | |
| 15 | `test: add Guardian integration tests` | |
| 16 | `test: update L4 E2E checklist for Guardian` | |
| 17 | `docs: update architecture docs and README` | |

# 03 - AI Guardian: Detailed Design

> Atomic commits, data structures, module layout, and four-layer test plan for the AI Guardian feature defined in [02-ai-guardian.md](02-ai-guardian.md).

## Module Layout

### New Swift Modules

| File | Purpose |
|------|---------|
| `Sources/CodoCore/MessageRouter.swift` | Decode raw JSON, dispatch `CodoMessage` vs hook event (raw bytes) |
| `Sources/CodoCore/GuardianProcess.swift` | Spawn/restart/kill TS child process, stdin/stdout line pipe |
| `Sources/CodoCore/GuardianProtocol.swift` | `GuardianProvider` protocol (fire-and-forget line sending) |
| `Sources/CodoCore/KeychainService.swift` | Read/write API key via Security.framework |
| `Sources/CodoCore/GuardianSettings.swift` | UserDefaults wrapper for Guardian settings |
| `Sources/Codo/SettingsWindow.swift` | NSWindow + NSViewController for settings panel |
| `Sources/Codo/SettingsViewModel.swift` | ObservableObject wrapper for settings binding (app target only) |
| `Sources/Codo/AppDelegate.swift` | Extended: Guardian lifecycle, menu items, settings trigger |

### New TypeScript Modules

| File | Purpose |
|------|---------|
| `guardian/main.ts` | Entry point — stdin line reader, event dispatch, event loop |
| `guardian/state.ts` | Three-layer state model (WorkingStateStore, EventBuffer, SummarySnapshot) |
| `guardian/llm.ts` | OpenAI-compatible client wrapper, tool definitions, prompt assembly |
| `guardian/classifier.ts` | Event classification (important / contextual / noise) |
| `guardian/fallback.ts` | Guardian OFF / LLM failure fallback mapping |
| `guardian/types.ts` | Shared TypeScript types (HookEvent, GuardianConfig, event stream messages) |
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
| `Sources/CodoCore/SocketServer.swift` | Refactor `handleClient()` to extract byte-reading, add `RawMessageHandler` path, preserve `MessageHandler` convenience |
| `Sources/CodoTestServer/CodoTestServer.swift` | Switch to `RawMessageHandler`, use `MessageRouter.route()` to handle both message types |
| `Package.swift` | No new targets — Guardian is TS/Bun, not Swift |

---

## Data Structures

### Swift Side

**Design principle**: The Swift daemon never decodes hook event payloads. It only peeks at the `_hook` field to decide routing, then forwards the original raw JSON bytes to the Guardian. No `HookEvent` struct exists in Swift — that type lives only in TypeScript where the Guardian actually inspects the fields.

#### `MessageRouter`

```swift
// Sources/CodoCore/MessageRouter.swift

/// Result of routing a raw JSON message.
public enum RoutedMessage: Sendable {
    /// Standard notification — decoded into CodoMessage.
    case notification(CodoMessage)
    /// Hook event — raw JSON bytes forwarded to Guardian as-is.
    /// `hook` is the event type (e.g., "stop", "notification"), extracted for logging only.
    case hookEvent(hook: String, rawJSON: Data)
}

public enum MessageRouterError: Error {
    case invalidJSON
}

/// Routes raw JSON to either CodoMessage or hook event path.
/// Does NOT decode hook events — only peeks at `_hook` field.
public enum MessageRouter {
    public static func route(_ data: Data) throws -> RoutedMessage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MessageRouterError.invalidJSON
        }

        if let hook = obj["_hook"] as? String {
            // Hook event: forward raw bytes, don't decode further
            return .hookEvent(hook: hook, rawJSON: data)
        } else {
            // Standard notification: decode as CodoMessage
            let message = try JSONDecoder().decode(CodoMessage.self, from: data)
            return .notification(message)
        }
    }
}
```

#### `GuardianProvider` Protocol

The daemon→Guardian channel is **fire-and-forget**: the daemon writes a JSON line to stdin and does not wait for a response. The Guardian reads events, processes them asynchronously, and writes notification commands to stdout when ready. The daemon reads stdout in a background loop and posts notifications.

This is NOT request-response JSON-RPC. It's a **bidirectional event stream**:

```
Daemon → Guardian (stdin):  one JSON line per event (fire-and-forget)
Guardian → Daemon (stdout): one JSON line per notification action (async)
```

```swift
// Sources/CodoCore/GuardianProtocol.swift

/// A notification action emitted by the Guardian on stdout.
public struct GuardianAction: Codable, Sendable {
    public let action: String  // "send" or "suppress"
    public let notification: CodoMessage?  // present when action == "send"
    public let reason: String?             // present when action == "suppress"
}

/// Protocol for Guardian communication, enabling testability.
public protocol GuardianProvider: Sendable {
    var isAlive: Bool { get }

    /// Send raw JSON line to Guardian stdin. Fire-and-forget — does not wait for response.
    func send(line: Data) async

    /// Start the Guardian process. Pass config via environment variables.
    func start(config: [String: String]) throws

    /// Stop the Guardian process (SIGTERM).
    func stop()
}
```

**No `AnyCodable`, no `GuardianConfig` struct in Swift.** Configuration is passed to the Guardian as environment variables:

```swift
// In GuardianProcess.start():
process.environment = [
    "CODO_API_KEY": apiKey,       // from KeychainService
    "CODO_BASE_URL": baseURL,     // from GuardianSettings
    "CODO_MODEL": model,          // from GuardianSettings
    "CODO_CONTEXT_LIMIT": "\(contextLimit)",
]
```

This avoids introducing any generic JSON types into Swift. The daemon's Swift type system only models what it actually inspects: `CodoMessage`, `RoutedMessage`, and `GuardianAction`.

#### `GuardianProcess`

```swift
// Sources/CodoCore/GuardianProcess.swift

/// Manages the Guardian child process lifecycle.
///
/// Communication model:
/// - Daemon writes JSON lines to stdin (fire-and-forget, never blocks)
/// - A background thread reads stdout lines and decodes GuardianAction
/// - When action == "send", it posts the notification via NotificationService
/// - All stdin writes are serialized through a DispatchQueue
/// - All stdout reads happen on a dedicated Thread (same pattern as SocketServer accept loop)
public final class GuardianProcess: GuardianProvider, @unchecked Sendable {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private let writeQueue = DispatchQueue(label: "codo.guardian.stdin")
    private let notificationService: NotificationService
    private let guardianPath: String  // path to guardian/main.ts
    private var restartCount: Int = 0
    private let maxRestarts = 3

    /// send(line:) writes raw JSON + newline to stdin.
    /// Serialized via writeQueue. Never blocks the caller.
    public func send(line: Data) async {
        writeQueue.async { [weak self] in
            guard let pipe = self?.stdinPipe else { return }
            var data = line
            data.append(UInt8(ascii: "\n"))
            pipe.fileHandleForWriting.write(data)
        }
    }

    /// Background stdout reader (runs on dedicated thread).
    /// Decodes each line as GuardianAction and dispatches to NotificationService.
    private func readStdoutLoop() {
        guard let handle = stdoutPipe?.fileHandleForReading else { return }
        // Read line-by-line, decode GuardianAction, post notification
        // This runs on a dedicated thread, so blocking reads are fine
    }
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

#### `GuardianSettings`

**Layer separation**: `CodoCore` contains a plain `struct GuardianSettings` with no UI dependencies. The app target (`Sources/Codo/`) wraps it in an `ObservableObject` view model for the settings window. This keeps `CodoCore` free of Combine/observation imports.

```swift
// Sources/CodoCore/GuardianSettings.swift

/// Pure data model for Guardian settings. No UI dependencies.
/// Reads/writes UserDefaults, but has no observation/binding support.
public struct GuardianSettings {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key: String {
        case guardianEnabled  = "guardianEnabled"
        case baseURL          = "guardianBaseURL"
        case model            = "guardianModel"
        case contextLimit     = "guardianContextLimit"
    }

    public var guardianEnabled: Bool {
        get { defaults.bool(forKey: Key.guardianEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.guardianEnabled.rawValue) }
    }

    public var baseURL: String {
        get { defaults.string(forKey: Key.baseURL.rawValue) ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: Key.baseURL.rawValue) }
    }

    public var model: String {
        get { defaults.string(forKey: Key.model.rawValue) ?? "gpt-4o-mini" }
        set { defaults.set(newValue, forKey: Key.model.rawValue) }
    }

    public var contextLimit: Int {
        get {
            let v = defaults.integer(forKey: Key.contextLimit.rawValue)
            return v > 0 ? v : 160_000
        }
        set { defaults.set(newValue, forKey: Key.contextLimit.rawValue) }
    }

    /// Serialize to environment variables for Guardian child process.
    public func toEnvironment(apiKey: String) -> [String: String] {
        [
            "CODO_API_KEY": apiKey,
            "CODO_BASE_URL": baseURL,
            "CODO_MODEL": model,
            "CODO_CONTEXT_LIMIT": "\(contextLimit)",
        ]
    }
}
```

```swift
// Sources/Codo/SettingsViewModel.swift (app target only)

import CodoCore
import Combine

/// Observable wrapper for SettingsWindow binding. Lives in app target, not CodoCore.
final class SettingsViewModel: ObservableObject {
    private var settings: GuardianSettings

    @Published var guardianEnabled: Bool { didSet { settings.guardianEnabled = guardianEnabled } }
    @Published var baseURL: String { didSet { settings.baseURL = baseURL } }
    @Published var model: String { didSet { settings.model = model } }
    @Published var contextLimit: Int { didSet { settings.contextLimit = contextLimit } }

    init(settings: GuardianSettings = GuardianSettings()) {
        self.settings = settings
        self.guardianEnabled = settings.guardianEnabled
        self.baseURL = settings.baseURL
        self.model = settings.model
        self.contextLimit = settings.contextLimit
    }
}
```

### TypeScript Side

#### `guardian/types.ts`

```typescript
// Event stream types (NOT JSON-RPC — bidirectional line-delimited JSON)

// Daemon → Guardian (stdin): one JSON line per event
// The daemon writes the raw hook JSON (with _hook field) or a CodoMessage directly.
// No envelope, no id, no method — just the payload itself.
// The Guardian determines event type by checking for `_hook` field (same discriminator as Swift side).

// Guardian → Daemon (stdout): one JSON line per action
export interface GuardianAction {
  action: "send" | "suppress";
  notification?: NotificationPayload;  // present when action == "send"
  reason?: string;                     // present when action == "suppress"
}

export interface GuardianResult {
  action: "send" | "suppress";
  notification?: NotificationPayload;
  reason?: string;
}

// NOTE: GuardianResult and GuardianAction are identical — the Guardian emits
// actions on stdout in the same shape. Kept as two names for clarity:
// GuardianResult is used in TypeScript internally, GuardianAction is the wire type
// that the Swift daemon decodes from stdout.

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
  cwd?: string;                // optional — absent in SessionEnd
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
  cwd?: string;             // optional — absent in SessionEnd
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

The current `SocketServer` decodes JSON into `CodoMessage` internally (`handleClient()` at line 171 calls `JSONDecoder().decode(CodoMessage.self, ...)`). For the discriminated union to work, the server must hand **raw bytes** to the handler so `MessageRouter` can inspect `_hook` first.

### Before

```swift
public typealias MessageHandler = @Sendable (CodoMessage) -> CodoResponse
// SocketServer: read bytes → decode CodoMessage → validate → handler(message)
```

### After

```swift
public typealias RawMessageHandler = @Sendable (Data) -> CodoResponse
// SocketServer: read bytes → handler(rawBytes)
// Handler is now responsible for decoding and validation
```

**This is not just adding a new initializer.** The core `handleClient()` method must be refactored:

1. Extract the "read bytes until newline" loop into a helper that returns `Data`
2. Remove the internal `JSONDecoder().decode(CodoMessage.self, ...)` and `message.validate()` calls from `handleClient()`
3. Pass raw `Data` to the stored handler
4. The `MessageHandler` convenience init wraps the old handler by inserting the decode + validate logic that was previously in `handleClient()`

```swift
// New handleClient() — simplified
private static func handleClient(socket: Int32, handler: RawMessageHandler) {
    defer { Darwin.close(socket) }
    // ... timeout setup ...
    guard let data = readUntilNewline(socket: socket) else { return }
    guard data.count <= maxPayloadSize else { return }
    let response = handler(data)
    sendResponse(response, to: socket)
}

// Legacy convenience init
public convenience init(socketPath: String, handler: @escaping MessageHandler) {
    self.init(socketPath: socketPath, rawHandler: { data in
        do {
            let message = try JSONDecoder().decode(CodoMessage.self, from: data)
            if let err = message.validate() { return .error(err) }
            return handler(message)
        } catch {
            return .error("invalid json")
        }
    })
}
```

**Regression risk**: All 16 existing socket tests continue to use the `MessageHandler` convenience init, so they validate backward compatibility automatically. New tests specifically exercise the `RawMessageHandler` path.

### AppDelegate Handler: Async Dispatch for Hooks

The handler closure returned to `SocketServer` must be **synchronous** (it returns `CodoResponse`). The critical question is what happens on the hook path.

**Answer**: The handler returns `.ok` immediately for both paths. Hook events are dispatched asynchronously via `Task.detached`:

```swift
// In AppDelegate.startDaemon():
socketServer = SocketServer(socketPath: socketPath, rawHandler: { [weak self] data in
    guard let self else { return .error("shutting down") }

    let routed: RoutedMessage
    do {
        routed = try MessageRouter.route(data)
    } catch {
        return .error("invalid json")
    }

    switch routed {
    case .notification(let message):
        if let err = message.validate() { return .error(err) }
        // Existing sync→async bridge for NotificationService
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: CodoResponse = .error("timeout")
        Task.detached {
            result = await self.notificationService.post(message: message)
            semaphore.signal()
        }
        semaphore.wait()
        return result

    case .hookEvent(_, let rawJSON):
        // Fire-and-forget: respond ok immediately, process async
        if let guardian = self.guardian, guardian.isAlive {
            Task.detached { await guardian.send(line: rawJSON) }
        } else {
            // Guardian OFF or dead: deliver fallback notification async
            Task.detached { await self.deliverFallback(rawJSON: rawJSON) }
        }
        return .ok  // ← CLI gets ok immediately, Guardian processes in background
    }
})
```

**This is the core latency contract from 02-ai-guardian.md**: hook events return `.ok` synchronously. The Guardian processes asynchronously. The CLI never waits for AI processing.

---

## Atomic Commits

Each commit is independently testable. Tests are written **before or alongside** the implementation (TDD).

| # | Type | Message | Files Changed | Tests Added |
|---|------|---------|---------------|-------------|
| 1 | `docs` | `docs: add AI Guardian detailed design` | `docs/features/03-ai-guardian-detail.md`, `docs/features/README.md` | — |
| 2 | `feat` | `feat: add MessageRouter for discriminated union dispatch` | `Sources/CodoCore/MessageRouter.swift` | `Tests/CodoCoreTests/MessageRouterTests.swift` |
| 3 | `refactor` | `refactor: add raw handler to SocketServer` | `Sources/CodoCore/SocketServer.swift` | `Tests/CodoCoreTests/SocketTests.swift` (update) |
| 4 | `feat` | `feat: add --hook flag to CLI` | `cli/codo.ts` | `cli/codo.test.ts` (new hook tests) |
| 5 | `test` | `test: add hook event integration tests` | `Sources/CodoTestServer/CodoTestServer.swift`, `scripts/integration-test.sh` | L3: hook event roundtrip |
| 6 | `feat` | `feat: add KeychainService and GuardianSettings` | `Sources/CodoCore/KeychainService.swift`, `Sources/CodoCore/GuardianSettings.swift` | `Tests/CodoCoreTests/GuardianSettingsTests.swift` |
| 7 | `feat` | `feat: add GuardianProtocol and GuardianProcess` | `Sources/CodoCore/GuardianProtocol.swift`, `Sources/CodoCore/GuardianProcess.swift` | `Tests/CodoCoreTests/GuardianProcessTests.swift` |
| 8 | `feat` | `feat: add settings window UI` | `Sources/Codo/SettingsWindow.swift`, `Sources/Codo/SettingsViewModel.swift` | L4: manual visual check |
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

#### Commit 2: `feat: add MessageRouter for discriminated union dispatch`

Create the routing logic that peeks at raw JSON to determine message type.

**`Sources/CodoCore/MessageRouter.swift`**:
- `RoutedMessage` enum: `.notification(CodoMessage)` | `.hookEvent(hook:rawJSON:)`
- `MessageRouter.route(_ data: Data)` — peek JSON for `_hook`, branch accordingly
- `MessageRouterError` — `invalidJSON`
- No `HookEvent` struct — hook events stay as raw `Data` bytes

**Tests** (`Tests/CodoCoreTests/MessageRouterTests.swift`):
| Test | Input | Expected |
|------|-------|----------|
| route CodoMessage | `{"title":"T"}` | `.notification(CodoMessage)` |
| route CodoMessage with all fields | `{"title":"T","subtitle":"S","threadId":"t"}` | `.notification(...)` with all fields |
| route HookEvent stop | `{"_hook":"stop","session_id":"s1","cwd":"/tmp"}` | `.hookEvent(hook:"stop", rawJSON: ...)` |
| route HookEvent notification | `{"_hook":"notification","title":"P"}` | `.hookEvent(hook:"notification", ...)` |
| route invalid JSON | `"not json"` | throws `invalidJSON` |
| route empty object | `{}` | throws (no title, no _hook → CodoMessage decode fails) |
| route CodoMessage missing title | `{"body":"B"}` | throws `invalidJSON` (no `_hook` and CodoMessage decode fails) |
| hook event preserves raw JSON | `{"_hook":"stop","custom":123}` | rawJSON contains original bytes |

#### Commit 3: `refactor: add raw handler to SocketServer`

**This is a non-trivial refactor of the core read/decode loop**, not just a new init.

**`Sources/CodoCore/SocketServer.swift`**:
- Add `RawMessageHandler = @Sendable (Data) -> CodoResponse` typedef
- **Refactor `handleClient()`**: extract byte-reading into a helper method, remove the internal `JSONDecoder.decode(CodoMessage.self, ...)` and `message.validate()` calls. The handler now receives raw `Data`.
- Add `init(socketPath:rawHandler:)` — stores `rawHandler` directly
- **Preserve `init(socketPath:handler:)`** as a convenience that wraps `MessageHandler` in a `RawMessageHandler` (inserts the decode + validate logic that was removed from `handleClient`)
- `CodoTestServer` continues using the `MessageHandler` convenience, so all existing L3 tests are unaffected

**Key refactor steps**:
1. Extract `readUntilNewline(socket:) -> Data?` from `handleClient()`
2. `handleClient()` calls `readUntilNewline()`, then passes raw `Data` to `rawHandler`
3. Convenience init injects decode + validate into the `rawHandler` wrapper

**Tests**: All 16 existing socket/integration tests continue to pass (they use `MessageHandler` convenience init → backward compat). New tests:
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
- Use `MessageRouter.route()` to decode incoming bytes
- For `.notification(CodoMessage)`: log JSON as before, return `.ok` (or `.error` for "fail-me")
- For `.hookEvent(_, rawJSON)`: log raw JSON bytes to `messages.log`, return `.ok`
- This means the test server can now receive both CodoMessage and hook events on the same socket

**`scripts/integration-test.sh`** — new section `--- Hook events ---`:
| Test | Scenario | Expected |
|------|----------|----------|
| `--hook stop` roundtrip | pipe JSON to CLI with `--hook stop` | server log shows `_hook: "stop"` |
| `--hook notification` roundtrip | pipe notification JSON | server log shows `_hook: "notification"` |
| `--hook post-tool-use` roundtrip | pipe PostToolUse JSON | server log shows tool data |
| hook preserves all fields | stdin with `session_id`, `cwd`, `tool_name` etc. | all fields in server log |
| existing CodoMessage unaffected | same old tests | all still pass |

#### Commit 6: `feat: add KeychainService and GuardianSettings`

**`Sources/CodoCore/KeychainService.swift`**:
- `readAPIKey()`, `writeAPIKey(_:)`, `deleteAPIKey()` using Security.framework
- Uses `kSecClassGenericPassword` with service `"ai.hexly.codo.01"` and account `"guardian-api-key"`

**`Sources/CodoCore/GuardianSettings.swift`**:
- `GuardianSettings` struct (plain data, no UI dependencies) with UserDefaults read/write
- Properties: `guardianEnabled`, `baseURL`, `model`, `contextLimit`
- `toEnvironment(apiKey:) -> [String: String]` for passing config to Guardian child process via env vars

**Tests** (`Tests/CodoCoreTests/GuardianSettingsTests.swift`):
| Test | Scenario | Expected |
|------|----------|----------|
| default values | fresh GuardianSettings | enabled=false, baseURL=openai, model=gpt-4o-mini, contextLimit=160000 |
| read/write guardianEnabled | toggle on/off | persists and reads back |
| read/write baseURL | custom URL | persists |
| read/write model | custom model | persists |
| toEnvironment | all settings + apiKey | dict with CODO_API_KEY, CODO_BASE_URL, CODO_MODEL, CODO_CONTEXT_LIMIT |

**Note**: `KeychainService` unit tests are difficult because they require a real Keychain. Tests use a mock wrapper or skip Keychain in CI — tested manually in L4.

#### Commit 7: `feat: add GuardianProtocol and GuardianProcess`

**`Sources/CodoCore/GuardianProtocol.swift`**:
- `GuardianProvider` protocol: `isAlive`, `send(line:)` (fire-and-forget), `start(config:)`, `stop()`
- `GuardianAction` struct: `action` ("send"/"suppress"), `notification?`, `reason?`
- `MockGuardianProvider` for testing (records sent lines, simulates crash/restart)

**`Sources/CodoCore/GuardianProcess.swift`**:
- `GuardianProcess` — spawns `bun guardian/main.ts` as child process
- Stdin pipe for writing JSON lines (serialized via `DispatchQueue`)
- Stdout reader on dedicated `Thread` — decodes `GuardianAction` lines, calls `NotificationService.post()` for "send" actions
- Config passed via environment variables (no `GuardianConfig` Swift struct)
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
- Save button commits to `GuardianSettings` + Keychain
- Cancel button dismisses

**`Sources/Codo/SettingsViewModel.swift`**:
- `SettingsViewModel: ObservableObject` wrapping `GuardianSettings`
- `@Published` properties for two-way binding in SettingsWindow
- Lives in app target to keep CodoCore free of Combine imports

No automated tests — UI is L4 manual verification.

#### Commit 9: `refactor: wire MessageRouter and Guardian into AppDelegate`

**`Sources/Codo/AppDelegate.swift`**:
- Replace `SocketServer(handler:)` with `SocketServer(rawHandler:)`
- Raw handler calls `MessageRouter.route()`
- `.notification(msg)` → existing sync→async bridge to `NotificationService` (unchanged)
- `.hookEvent(hook, rawJSON)` → **returns `.ok` immediately**, then:
  - Guardian alive: `Task.detached { await guardian.send(line: rawJSON) }` (fire-and-forget)
  - Guardian dead/OFF: `Task.detached { await self.deliverFallback(rawJSON: rawJSON) }` (fire-and-forget)
  - This is the core latency contract: hook events never block the CLI
- Menu: add "AI Guardian" toggle item, "Settings..." item
- On toggle: spawn or kill Guardian process
- On startup: if `guardianEnabled` && API key present → spawn Guardian
- Add `deliverFallback(rawJSON:)` method: peek `_hook` field, use `fallbackNotification()` logic (hardcoded in Swift, matching the table from 02-ai-guardian.md), deliver via `NotificationService`

**Tests**: Update `MessageRouterTests.swift` with:
| Test | Scenario | Expected |
|------|----------|----------|
| route + handler CodoMessage | send `{"title":"T"}` via raw handler | NotificationService receives it |
| route + handler HookEvent, guardian ON | send `{"_hook":"stop",...}` via raw handler | MockGuardianProvider receives line |
| route + handler HookEvent, guardian OFF | send `{"_hook":"stop",...}` via raw handler | fallback notification delivered |
| hook path returns ok immediately | send hook event | handler returns `.ok` before Guardian processes |

These test the routing logic using mock providers, not real AppDelegate or process spawn.

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
| stdin parse | JSON line on stdin | parsed as event |
| stdout action | send action | GuardianAction JSON line on stdout |
| hook event dispatch | hook event line | classified, state updated, LLM called if needed |
| CodoMessage dispatch | CodoMessage line (no `_hook`) | processed as direct notification |
| malformed JSON | invalid JSON line | error logged, no crash |
| sequential events | 3 events in sequence | all processed, state accumulated |

---

## Four-Layer Test Plan

### L1 — Unit Tests

**Swift** (`swift test`): Existing 46 tests + new tests below.

| File | New Tests | Count |
|------|-----------|-------|
| `Tests/CodoCoreTests/MessageRouterTests.swift` | Route CodoMessage, route hook event, invalid JSON, preserve raw bytes, handler integration with mock providers | ~10 |
| `Tests/CodoCoreTests/SocketTests.swift` | Raw handler refactor: readUntilNewline, raw handler receives data, legacy handler compat, hook event through raw handler | ~4 |
| `Tests/CodoCoreTests/GuardianSettingsTests.swift` | Default values, read/write each setting, toEnvironment | ~5 |
| `Tests/CodoCoreTests/GuardianProcessTests.swift` | Mock provider: send line, isAlive, stop, restart exceeded, stdout reader mock | ~5 |
| **Subtotal** | | **~24 new** |

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
| `guardian/main.test.ts` | stdin/stdout, event line dispatch, state accumulation | ~7 |
| **Subtotal** | | **~60 new** |

**Estimated totals after Guardian**:
- Swift: ~70 tests (46 + 24)
- TS CLI: ~69 tests (60 + 9)
- TS Guardian: ~60 tests
- **Total L1: ~199 tests**

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

**Mock Guardian for L3**: A minimal Bun script (`scripts/mock-guardian.ts`) that reads JSON lines from stdin and writes a fixed `send` action to stdout. The test server spawns this instead of the real Guardian.

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
| 1 | `docs: add AI Guardian detailed design` | ✅ Done |
| 2 | `feat: add MessageRouter for discriminated union dispatch` | ✅ Done (05dee58) |
| 3 | `refactor: add raw handler to SocketServer` | ✅ Done (b023811) |
| 4 | `feat: add --hook flag to CLI` | ✅ Done (030d791) |
| 5 | `test: add hook event integration tests` | ✅ Done (83d08c3) |
| 6 | `feat: add KeychainService and GuardianSettings` | ✅ Done (a481656) |
| 7 | `feat: add GuardianProtocol and GuardianProcess` | ✅ Done (52f217d) |
| 8 | `feat: add settings window UI` | ✅ Done (c361494) |
| 9 | `refactor: wire MessageRouter and Guardian into AppDelegate` | ✅ Done (bd00436) |
| 10 | `feat: add Guardian state module` | ✅ Done (005363d) — types + classifier |
| 11 | `feat: add event classifier` | ✅ Done (005363d) — shipped with #10 |
| 12 | `feat: add fallback notification mapping` | ✅ Done (ea31a02) |
| 13 | `feat: add LLM client and prompt assembly` | ✅ Done (bd5319d) |
| 14 | `feat: add Guardian main entry point` | ✅ Done (5e109d5) |
| 15 | `test: add Guardian integration tests` | ✅ Done (ad42c88) |
| 16 | `test: update L4 E2E checklist for Guardian` | ✅ Done (1fc5a51) |
| 17 | `docs: update architecture docs and README` | ✅ Done (96d4c58) |

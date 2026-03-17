# 02 - IPC Protocol

> Unix Domain Socket protocol specification for CLI ↔ Daemon communication.

## Socket Path

```
~/.codo/codo.sock
```

- Directory `~/.codo/` created on daemon first launch (mode `0700`)
- Socket file created with mode `0600`
- Socket file removed on clean shutdown
- Stale socket detected on startup via connectivity test

## Connection Lifecycle

```
CLI (client)                          Daemon (server)
    │                                      │
    ├──── connect() ──────────────────────►│
    │                                      │
    ├──── send(JSON + "\n") ──────────────►│
    │                                      │  parse JSON
    │                                      │  validate fields
    │                                      │  submit to UNUserNotificationCenter
    │                                      │
    │◄──── send(response JSON + "\n") ─────┤
    │                                      │
    │  (either side closes)                │
    └──────────────────────────────────────┘
```

**Request/response protocol**: one exchange per connection. Client sends a request, daemon processes it synchronously, daemon sends a response, connection closes.

No persistent connections, no multiplexing.

## Message Format

### Request (CLI → Daemon)

```json
{
  "title": "Build Done",
  "body": "All 42 tests passed",
  "sound": "default"
}
```

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `title` | `String` | ✅ | — | Notification title (first line) |
| `body` | `String` | ❌ | `nil` | Notification body text |
| `sound` | `String` | ❌ | `"default"` | `"default"` or `"none"` |

### Response (Daemon → CLI)

**Success**:
```json
{"ok": true}
```

**Failure**:
```json
{"ok": false, "error": "notification permission denied"}
```

| Field | Type | Always | Description |
|-------|------|--------|-------------|
| `ok` | `Bool` | ✅ | Whether the message was accepted and submitted to the notification system |
| `error` | `String` | ❌ | Human-readable error when `ok=false` |

### `ok: true` Semantics

`ok: true` means:
1. JSON was valid
2. Required fields were present
3. Message was successfully submitted to `UNUserNotificationCenter.add()`

`ok: true` does **NOT** guarantee the user saw the notification. macOS may suppress it due to:
- Focus / Do Not Disturb mode
- Notification center settings
- System load

This is by design — the daemon controls submission, macOS controls display.

### `ok: false` Error Strings

| `error` value | Meaning |
|---------------|---------|
| `"invalid json"` | Could not parse request as JSON |
| `"title is required"` | Missing or empty `title` field |
| `"notification permission denied"` | User denied notification permission in System Settings |
| `"notifications unavailable (no app bundle)"` | Daemon running as bare binary without `.app` bundle (dev mode) |
| `"notification failed: <system error>"` | `UNUserNotificationCenter.add()` returned an error |

## Encoding

- UTF-8
- Newline-delimited (`\n` terminator after each JSON object)
- Single JSON object per connection (no streaming)
- Max message size: **64 KB** (reject larger payloads — close without response)

## Error Handling

### Client-side (CLI)

| Condition | CLI Behavior | Exit Code |
|-----------|-------------|-----------|
| Socket file missing | stderr: `"codo daemon not running"` | 2 |
| Connection refused | stderr: `"cannot connect to codo daemon"` | 3 |
| Write timeout (5s) | stderr: `"send timeout"` | 3 |
| Read timeout (5s) | stderr: `"response timeout"` | 3 |
| Invalid response JSON | stderr: `"unexpected response from daemon"` | 3 |
| `ok: false` response | stderr: error string from daemon | 1 |

### Server-side (Daemon)

| Condition | Daemon Behavior |
|-----------|----------------|
| Valid request, notification submitted | Respond `{"ok":true}`, close |
| Invalid JSON | Respond `{"ok":false,"error":"invalid json"}`, close |
| Missing `title` | Respond `{"ok":false,"error":"title is required"}`, close |
| Permission denied | Respond `{"ok":false,"error":"notification permission denied"}`, close |
| No app bundle (dev mode) | Respond `{"ok":false,"error":"notifications unavailable (no app bundle)"}`, close |
| Notification system error | Respond `{"ok":false,"error":"notification failed: <detail>"}`, close |
| Payload > 64KB | Close connection immediately (no response) |
| Read timeout (5s) | Close connection (no response) |

## Stale Socket Detection

On daemon startup:

```
1. Check if ~/.codo/codo.sock exists
2. If yes → attempt connect()
3. If connect succeeds → another instance running → print error to stderr, exit(1)
4. If connect fails (ECONNREFUSED / ENOENT on connect) → stale socket → unlink(), proceed with bind()
```

No flock, no PID file. Connectivity test is sufficient for this project's scope.

## Security

- Socket file mode: `0600` (owner read/write only)
- Directory mode: `0700` (owner only)
- No authentication — trust is implicit (same-user, local-only)
- No encryption — local IPC, no network exposure

## Wire Examples

### Minimal notification

```bash
echo '{"title":"Done"}' | codo
```

```
→ {"title":"Done"}\n
← {"ok":true}\n
```

CLI exit code: `0`

### Full notification

```bash
echo '{"title":"Build Failed","body":"3 tests failed in AuthModule","sound":"default"}' | codo
```

```
→ {"title":"Build Failed","body":"3 tests failed in AuthModule","sound":"default"}\n
← {"ok":true}\n
```

### Silent notification

```bash
echo '{"title":"Deploying...","body":"ETA 2min","sound":"none"}' | codo
```

```
→ {"title":"Deploying...","body":"ETA 2min","sound":"none"}\n
← {"ok":true}\n
```

### Permission denied

```bash
echo '{"title":"Hello"}' | codo
```

```
→ {"title":"Hello"}\n
← {"ok":false,"error":"notification permission denied"}\n
```

CLI stderr: `notification permission denied`
CLI exit code: `1`

### Daemon not running

```bash
echo '{"title":"Hello"}' | codo
```

No socket file exists.
CLI stderr: `codo daemon not running`
CLI exit code: `2`

# 02 - IPC Protocol

> Unix Domain Socket protocol between Swift daemon and TypeScript CLI.

## Socket Path

```
~/.codo/codo.sock
```

- Directory `~/.codo/` created by daemon on first launch (mode `0700`)
- Socket file mode `0600`
- Removed on clean daemon shutdown
- Stale socket detected on daemon startup via connectivity test

## Connection Lifecycle

```
CLI (TypeScript)                      Daemon (Swift)
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

Request/response, one exchange per connection. No persistent connections.

## Message Format

### Request (CLI → Daemon)

```json
{"title": "Build Done", "body": "All 42 tests passed", "subtitle": "✅ Success", "sound": "default", "threadId": "build"}
```

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `title` | `String` | ✅ | — | Notification title |
| `body` | `String` | ❌ | `nil` | Notification body text |
| `subtitle` | `String` | ❌ | `nil` | Notification subtitle (below title, above body) |
| `sound` | `String` | ❌ | `"default"` | `"default"` or `"none"` |
| `threadId` | `String` | ❌ | `nil` | Groups notifications in Notification Center |

### Response (Daemon → CLI)

```json
{"ok": true}
```

```json
{"ok": false, "error": "notification permission denied"}
```

| Field | Type | Always | Description |
|-------|------|--------|-------------|
| `ok` | `Bool` | ✅ | Message accepted and submitted to notification system |
| `error` | `String` | ❌ | Human-readable error when `ok=false` |

### `ok: true` Semantics

Means: JSON valid + fields valid + submitted to `UNUserNotificationCenter.add()`.

Does NOT guarantee user saw the toast. macOS may suppress (Focus, DND, settings).

### Error Strings

| `error` | Meaning |
|---------|---------|
| `"invalid json"` | Cannot parse request |
| `"title is required"` | Missing or empty `title` |
| `"notification permission denied"` | User denied in System Settings |
| `"notifications unavailable (no app bundle)"` | Dev-only safety net: bare binary without `.app` bundle. Not a production path |
| `"notification failed: <detail>"` | System error from `UNUserNotificationCenter.add()` |

## Encoding

- UTF-8, newline-delimited (`\n` terminator)
- Single JSON object per connection
- Max message size: **64 KB** (close without response if exceeded)

## Error Handling

### CLI-side

| Condition | stderr | Exit Code |
|-----------|--------|-----------|
| Socket file missing | `codo daemon not running` | 2 |
| Connection refused | `cannot connect to codo daemon` | 3 |
| Write/read timeout (5s) | `timeout` | 3 |
| Invalid response | `unexpected response from daemon` | 3 |
| `ok: false` | error string from daemon | 1 |

### Daemon-side

| Condition | Response |
|-----------|----------|
| Valid request, notification submitted | `{"ok":true}` |
| Invalid JSON | `{"ok":false,"error":"invalid json"}` |
| Missing `title` | `{"ok":false,"error":"title is required"}` |
| Permission denied | `{"ok":false,"error":"notification permission denied"}` |
| No app bundle (dev only) | `{"ok":false,"error":"notifications unavailable (no app bundle)"}` |
| System error | `{"ok":false,"error":"notification failed: <detail>"}` |
| Payload > 64KB | Close immediately (no response) |
| Read timeout (5s) | Close (no response) |

## Stale Socket Detection

On daemon startup:

```
1. ~/.codo/codo.sock exists?
2. Yes → connect()
3. Connect succeeds → another instance → print error, exit(1)
4. Connect fails → stale → unlink(), proceed with bind()
```

## Security

- Socket `0600`, directory `0700` — owner-only
- No auth — same-user trust, local only
- No encryption — local IPC

## Wire Examples

```
# Happy path (minimal — title only)
→ {"title":"Done"}\n
← {"ok":true}\n

# With all fields
→ {"title":"Build Failed","body":"3 tests failed","subtitle":"❌ Error","sound":"default","threadId":"build"}\n
← {"ok":true}\n

# Backward compatible (old client, no subtitle/threadId)
→ {"title":"Build Failed","body":"3 tests failed","sound":"default"}\n
← {"ok":true}\n

# Permission denied
→ {"title":"Hello"}\n
← {"ok":false,"error":"notification permission denied"}\n
```

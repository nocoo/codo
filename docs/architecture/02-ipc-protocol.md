# 02 - IPC Protocol

> Unix Domain Socket protocol specification for CLI ↔ Daemon communication.

## Socket Path

```
~/.codo/codo.sock
```

- Directory `~/.codo/` created on daemon first launch
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
    │                                      │  post notification
    │◄──── send(ack JSON + "\n") ──────────┤
    │                                      │
    ├──── close() ────────────────────────►│
    │                                      │
```

One message per connection. No persistent connections, no multiplexing. This keeps both sides trivially simple.

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

```json
{
  "ok": true
}
```

```json
{
  "ok": false,
  "error": "notification permission denied"
}
```

| Field | Type | Always | Description |
|-------|------|--------|-------------|
| `ok` | `Bool` | ✅ | Whether notification was posted |
| `error` | `String` | ❌ | Human-readable error when `ok=false` |

## Encoding

- UTF-8
- Newline-delimited (`\n` terminator)
- Single JSON object per connection (no streaming)
- Max message size: **64 KB** (reject larger payloads)

## Error Handling

### Client-side

| Condition | CLI Behavior | Exit Code |
|-----------|-------------|-----------|
| Socket file missing | Print "codo daemon not running" to stderr | 2 |
| Connection refused | Print "cannot connect to codo daemon" to stderr | 3 |
| Write timeout (5s) | Print "send timeout" to stderr | 3 |
| Read timeout (5s) | Print "response timeout" to stderr | 3 |
| Invalid response | Print "unexpected response" to stderr | 3 |
| `ok: false` | Print error message to stderr | 1 |

### Server-side

| Condition | Daemon Behavior |
|-----------|----------------|
| Invalid JSON | Return `{"ok":false,"error":"invalid json"}`, close |
| Missing `title` | Return `{"ok":false,"error":"title is required"}`, close |
| Payload > 64KB | Close connection immediately |
| Read timeout (5s) | Close connection |
| Notification failed | Return `{"ok":false,"error":"..."}`, close |

## Stale Socket Detection

On daemon startup:

```
1. Check if ~/.codo/codo.sock exists
2. If yes → attempt connect()
3. If connect succeeds → another instance running → print message, exit
4. If connect fails → stale socket → unlink(), proceed with bind()
```

## Security

- Socket has **user-only permissions**: `chmod 0600 codo.sock`
- Directory `~/.codo/` has **user-only permissions**: `chmod 0700 ~/.codo/`
- No authentication — trust is implicit (same-user, local-only)
- No encryption — local IPC, no network exposure

## Wire Examples

### Minimal notification

```bash
echo '{"title":"Done"}' | codo
```

Wire bytes (client → server):
```
{"title":"Done"}\n
```

Wire bytes (server → client):
```
{"ok":true}\n
```

### Full notification

```bash
echo '{"title":"Build Failed","body":"3 tests failed in AuthModule","sound":"default"}' | codo
```

### Silent notification

```bash
echo '{"title":"Deploying...","body":"ETA 2min","sound":"none"}' | codo
```

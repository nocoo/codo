# Codo

macOS menubar daemon + CLI for displaying system toast notifications. Designed as a notification bridge for Claude Code hooks.

```bash
# From any Claude Code hook:
codo "Build Done" "All 42 tests passed"

# Or via stdin JSON:
echo '{"title":"Build Done","body":"All tests passed"}' | codo
```

## Architecture

Two layers: **Swift menubar app** (daemon, listens on Unix Domain Socket, shows toast) + **TypeScript CLI** (Bun script, sends messages to daemon).

## Docs

See [docs/](docs/) for design documents:

- [Architecture](docs/architecture/) — System design, IPC protocol, build, testing, MVP plan

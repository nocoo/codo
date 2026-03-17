# Codo

macOS menubar app that receives messages via CLI and displays them as system toast notifications. Designed as a notification bridge for local Claude Code hooks.

```
echo '{"title":"Build Done","body":"All tests passed"}' | codo
```

## Docs

See [docs/](docs/) for design documents:

- [Architecture](docs/architecture/) — System design, IPC protocol, build pipeline

# 05 - MVP Atomic Commits

> TDD implementation plan. Each phase = testable increment. Every commit passes all existing tests.

## Principles

- **Test-first**: write tests before implementation
- **Each commit compiles and passes tests**
- **No dead code**: nothing committed without a test exercising it

## Phases

### Phase 1 — Scaffold

| # | Commit | Content | Passes |
|---|--------|---------|--------|
| 1 | `chore: init spm project` | Package.swift (macOS 14+, CodoCore, Codo, CodoCoreTests), .gitignore, empty source stubs | `swift build` ✓ |
| 2 | `chore: init cli project` | `cli/package.json`, `cli/codo.ts` (shebang + --help stub), `cli/biome.json` | `bun cli/codo.ts --help` ✓ |
| 3 | `chore: add lint and git hooks` | `.swiftlint.yml`, `scripts/pre-commit.sh`, `scripts/pre-push.sh` | L2 ✓ |

### Phase 2 — Message Codec (TDD)

| # | Commit | Content | Passes |
|---|--------|---------|--------|
| 4 | `test: add message codec tests` | CodoCoreTests: decode/encode CodoMessage + CodoResponse, edge cases | Tests FAIL (types missing) |
| 5 | `feat: add message types` | CodoCore: `CodoMessage`, `CodoResponse`, Codable | All L1 ✓ |

### Phase 3 — Socket Server (TDD)

| # | Commit | Content | Passes |
|---|--------|---------|--------|
| 6 | `test: add socket server tests` | CodoCoreTests: roundtrip with mock handler on temp socket. Happy path, invalid JSON, missing title, stale socket, concurrent clients | Tests FAIL |
| 7 | `feat: add socket server` | CodoCore: `SocketServer` — bind, accept, read, decode, handler, respond, close. Injectable socket path | All L1 ✓ |

### Phase 4 — Notification Service (TDD)

| # | Commit | Content | Passes |
|---|--------|---------|--------|
| 8 | `test: add notification service tests` | CodoCoreTests: `NotificationProvider` protocol mock. Available/unavailable, granted/denied | Tests FAIL |
| 9 | `feat: add notification service` | CodoCore: protocol + `SystemNotificationProvider` (guarded) + `MockNotificationProvider` | All L1 ✓ |

### Phase 5 — CLI (TDD)

| # | Commit | Content | Passes |
|---|--------|---------|--------|
| 10 | `test: add cli tests` | `cli/codo.test.ts`: arg parsing, JSON construction, stdin, error cases | Tests FAIL |
| 11 | `feat: implement cli` | `cli/codo.ts`: arg parsing, stdin JSON, UDS connect, send/receive, exit codes | `bun test` ✓ |

### Phase 6 — Menubar App

| # | Commit | Content | Passes |
|---|--------|---------|--------|
| 12 | `feat: add menubar app` | Codo target: `CodoApp`, `AppDelegate`, NSStatusItem + bell icon, right-click menu, wire SocketServer + NotificationService | `swift build` ✓, manual: icon visible |

### Phase 7 — Bundle & Install

| # | Commit | Content | Passes |
|---|--------|---------|--------|
| 13 | `feat: add build and install scripts` | `Resources/Info.plist`, `scripts/build.sh`, `scripts/install.sh` | `./scripts/build.sh` ✓, `codesign -v` ✓ |

### Phase 8 — Integration & Polish

| # | Commit | Content | Passes |
|---|--------|---------|--------|
| 14 | `test: add integration tests` | `scripts/integration-test.sh`: start server on temp socket, CLI sends, assert response | L3 ✓ |
| 15 | `chore: run e2e checklist, finalize` | Fix any gaps from L4, ensure coverage ≥ 90% | All layers ✓ |

## Dependency Graph

```
Phase 1 (scaffold)
    │
    ├────────────────┐
    ▼                ▼
Phase 2 (codec)    Phase 5 (CLI)
    │                │
    ▼                │
Phase 3 (socket)    │
    │                │
    ▼                │
Phase 4 (notify)    │
    │                │
    ▼                │
Phase 6 (app) ◄─────┘
    │
    ▼
Phase 7 (bundle)
    │
    ▼
Phase 8 (integration)
```

Note: Phase 5 (CLI) can run in parallel with Phases 2-4 (Swift core), since CLI tests mock the socket. They converge at Phase 6.

## MVP Definition of Done

- [ ] `swift build` — no warnings
- [ ] `swift test` — all pass
- [ ] `swiftlint lint --strict` — pass
- [ ] `bun test` (in cli/) — all pass
- [ ] `bunx biome check` (in cli/) — pass
- [ ] `./scripts/build.sh` — signed `.app`
- [ ] `./scripts/integration-test.sh` — pass
- [ ] L4 E2E checklist — all checked
- [ ] `codo "MVP Done" "All layers green"` — macOS toast appears

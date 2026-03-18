# 05 - MVP Atomic Commits

> TDD implementation plan. Each commit is green (compiles + passes all tests). Red/green cycles happen within a commit, not across commits.

## Principles

- **TDD within each commit**: write tests → implement → both go in the same commit
- **Every commit is green**: compiles and passes `swift test` / `bun test`
- **No dead code**: nothing committed without a test exercising it

## Phases

### Phase 1 — Scaffold

| # | Commit | Content | Verify |
|---|--------|---------|--------|
| 1 | `chore: init spm project` | Package.swift (macOS 14+, CodoCore, Codo, CodoCoreTests), .gitignore, empty source stubs | `swift build` ✓ |
| 2 | `chore: init cli project` | `cli/package.json`, `cli/codo.ts` (shebang + --help stub), `cli/biome.json` | `bun cli/codo.ts --help` ✓ |
| 3 | `chore: add lint and git hooks` | `.swiftlint.yml`, `scripts/pre-commit.sh`, `scripts/pre-push.sh` | L2 ✓ |

### Phase 2 — Message Codec

| # | Commit | Content | Verify |
|---|--------|---------|--------|
| 4 | `feat: add message types with tests` | CodoCore: `CodoMessage`, `CodoResponse`. CodoCoreTests: decode/encode, edge cases (missing title, empty, garbage) | `swift test` ✓ |

### Phase 3 — Socket Server

| # | Commit | Content | Verify |
|---|--------|---------|--------|
| 5 | `feat: add socket server with tests` | CodoCore: `SocketServer` (bind, accept, read, decode, handler, respond, close). CodoCoreTests: roundtrip with mock handler on temp socket, invalid JSON, missing title, stale socket, concurrent clients | `swift test` ✓ |

### Phase 4 — Notification Service

| # | Commit | Content | Verify |
|---|--------|---------|--------|
| 6 | `feat: add notification service with tests` | CodoCore: `NotificationProvider` protocol, `SystemNotificationProvider` (guarded), `MockNotificationProvider`. CodoCoreTests: available/unavailable, granted/denied | `swift test` ✓ |

### Phase 5 — CLI

| # | Commit | Content | Verify |
|---|--------|---------|--------|
| 7 | `feat: implement cli with tests` | `cli/codo.ts`: arg parsing (title, body, --silent), stdin JSON, UDS connect, send/receive, exit codes, output contract (no stdout on success). `cli/codo.test.ts`: arg parsing, JSON construction, stdin, args-vs-stdin priority, error cases | `bun test` ✓ |

### Phase 6 — Menubar App

| # | Commit | Content | Verify |
|---|--------|---------|--------|
| 8 | `feat: add menubar app` | Codo target: `CodoApp`, `AppDelegate`, NSStatusItem + bell icon, right-click menu, wire SocketServer + NotificationService | `swift build` ✓, manual: icon visible |

### Phase 7 — Bundle & Install

| # | Commit | Content | Verify |
|---|--------|---------|--------|
| 9 | `feat: add build and install scripts` | `Resources/Info.plist`, `scripts/build.sh`, `scripts/install.sh` (copies CLI to `~/.codo/codo.ts`) | `./scripts/build.sh` ✓, `codesign -v` ✓ |

### Phase 8 — Integration & Polish

| # | Commit | Content | Verify |
|---|--------|---------|--------|
| 10 | `test: add integration tests` | `scripts/integration-test.sh`: start server on temp socket, CLI sends, assert exit code + no stdout + stderr | L3 ✓ |
| 11 | `chore: run e2e checklist, finalize` | Fix any gaps from L4, ensure coverage ≥ 90% | All layers ✓ |

## Dependency Graph

```
Phase 1 (scaffold)
    │
    ├──────────────┐
    ▼              ▼
Phase 2 (codec)  Phase 5 (CLI)
    │              │
    ▼              │
Phase 3 (socket)  │
    │              │
    ▼              │
Phase 4 (notify)  │
    │              │
    ▼              │
Phase 6 (app) ◄───┘
    │
    ▼
Phase 7 (bundle)
    │
    ▼
Phase 8 (integration)
```

Phase 5 (CLI) can run in parallel with Phases 2-4 (Swift core). They converge at Phase 6.

## MVP Definition of Done

- [ ] `swift build` — no warnings
- [ ] `swift test` — all pass, coverage ≥ 90% on CodoCore
- [ ] `swiftlint lint --strict` — pass
- [ ] `bun test` (in cli/) — all pass
- [ ] `bunx biome check` (in cli/) — pass
- [ ] `./scripts/build.sh` — signed `.app`
- [ ] `./scripts/integration-test.sh` — pass
- [ ] L4 E2E checklist — all checked
- [ ] `codo "MVP Done" "All layers green"` — macOS toast appears

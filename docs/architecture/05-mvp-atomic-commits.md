# 05 - MVP Atomic Commits

> TDD-driven implementation plan. Each phase delivers a testable increment. Every commit passes all existing tests.

## Principles

- **Test-first**: write tests before implementation in each phase
- **Each commit compiles and passes `swift test`**
- **Each phase ends with a working, testable slice**
- **No dead code**: nothing is committed "for later" without a test exercising it

## Phases

### Phase 1 — Project Scaffold

| # | Commit | Content | Tests |
|---|--------|---------|-------|
| 1 | `chore: init spm project` | Package.swift (macOS 14+, CodoCore target, Codo executable, CodoTests), .gitignore, .swiftlint.yml, empty source stubs | Compiles, `swift test` passes (0 tests) |
| 2 | `chore: add swiftlint and git hooks` | .swiftlint.yml (strict), scripts/pre-commit.sh, scripts/pre-push.sh, .githooks/ setup | L2 passes |

### Phase 2 — Message Codec (TDD)

| # | Commit | Content | Tests |
|---|--------|---------|-------|
| 3 | `test: add message codec tests` | CodoTests: CodoMessage decode/encode, CodoResponse encode, edge cases (missing title, empty, garbage) | Tests written, all FAIL (types don't exist yet) |
| 4 | `feat: add message types and codec` | CodoCore: `CodoMessage`, `CodoResponse`, `Codable` conformance, sound default logic | All L1 pass |

### Phase 3 — Socket IPC (TDD)

| # | Commit | Content | Tests |
|---|--------|---------|-------|
| 5 | `test: add socket roundtrip tests` | CodoTests: SocketServer + CLIClient roundtrip with mock handler, temp socket dir. Cases: happy path, invalid json, missing title, server not running | Tests written, all FAIL |
| 6 | `feat: add socket server` | CodoCore: `SocketServer` — bind, accept, read, decode, call handler, encode response, send, close. Uses temp socket path for testability (injectable path) | Socket tests pass |
| 7 | `feat: add cli client` | CodoCore: `CLIClient` — connect, send, read response, exit codes. Stdin reading with validation (empty, oversized) | All L1 + L3 pass |

### Phase 4 — Notification Service

| # | Commit | Content | Tests |
|---|--------|---------|-------|
| 8 | `test: add notification service tests` | CodoTests: NotificationService with protocol-based mock. Cases: available/unavailable, permission granted/denied | Tests written, FAIL |
| 9 | `feat: add notification service` | CodoCore: `NotificationProvider` protocol, `SystemNotificationProvider` (real UNUserNotificationCenter, guarded), `MockNotificationProvider` for tests | All tests pass |

### Phase 5 — MenuBar App Shell

| # | Commit | Content | Tests |
|---|--------|---------|-------|
| 10 | `feat: add menubar daemon` | Codo target: `CodoApp` entry point, `AppDelegate`, `NSStatusItem` with SF Symbol `bell`, right-click menu (version, Launch at Login, Quit), `.accessory` policy | Compiles. Manual verification: `swift run` shows icon (notifications won't work without bundle) |
| 11 | `feat: add mode router` | Codo target: main entry — flag detection (`--help`, `--version`), stdin detection (`isatty`), dispatch to CLI or daemon. Wire up SocketServer + NotificationService in daemon path | `codo --version` works, `echo '...' \| swift run Codo` sends to socket |

### Phase 6 — App Bundle & Install

| # | Commit | Content | Tests |
|---|--------|---------|-------|
| 12 | `feat: add app bundle pipeline` | `Resources/Info.plist`, `scripts/build.sh` (build + assemble + codesign) | `./scripts/build.sh` produces valid `.app`. `codesign -v` passes |
| 13 | `docs: add verification checklist` | L4 E2E checklist in docs, update README with install instructions | — |

### Phase 7 — Polish & Gate

| # | Commit | Content | Tests |
|---|--------|---------|-------|
| 14 | `test: add integration tests` | Socket lifecycle: stale cleanup, concurrent clients, client timeout | All L3 pass |
| 15 | `chore: verify coverage and finalize` | Ensure 90%+ CodoCore coverage, fix any gaps, run full L4 checklist | All layers green |

## Dependency Graph

```
Phase 1 (scaffold)
    │
    ▼
Phase 2 (codec)     ← no dependencies, pure data types
    │
    ▼
Phase 3 (socket)    ← depends on codec (message types)
    │
    ▼
Phase 4 (notify)    ← depends on codec (message types)
    │
    ├──────────────┐
    ▼              ▼
Phase 5 (app)    Phase 6 (bundle)
    │              │
    └──────┬───────┘
           ▼
    Phase 7 (polish)
```

## MVP Definition of Done

All of the following must be true:

- [ ] `swift build` compiles without warnings
- [ ] `swift test` passes (L1 unit + L3 integration)
- [ ] `swiftlint lint --strict` passes (L2)
- [ ] `./scripts/build.sh` produces signed `.app`
- [ ] L4 E2E checklist fully checked off
- [ ] `echo '{"title":"MVP Done","body":"All layers green"}' | codo` displays macOS toast

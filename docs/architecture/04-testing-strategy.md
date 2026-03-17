# 04 - Testing Strategy

> Four-layer testing adapted for a Swift macOS menubar app. MVP scope.

## Four Layers

| Layer | What | When | Tool |
|-------|------|------|------|
| **L1 — Unit Tests** | CodoCore logic: message codec, socket roundtrip, CLI client | pre-commit | `swift test` |
| **L2 — Lint** | Code style, zero warnings | pre-commit | SwiftLint (strict mode) |
| **L3 — Integration Tests** | Socket server ↔ CLI client end-to-end, in-process | pre-push | `swift test --filter Integration` |
| **L4 — E2E Checklist** | Full `.app` bundle: install, launch, permission, toast | Manual (pre-release) | Human + script |

### Why L4 is a manual checklist, not automated

The highest-risk area (bundle, signing, notification permission, toast display) depends on:
- macOS system UI (notification permission prompt)
- Code signature identity (machine-specific)
- `UNUserNotificationCenter` requiring a running app with bundle identifier

These cannot be reliably automated in CI or `swift test`. A checklist is more honest than a flaky test.

## L1 — Unit Tests

Target: `CodoTests`, depends on `CodoCore` only.

### Test Cases

**MessageCodec**:
| Test | Input | Expected |
|------|-------|----------|
| decode full message | `{"title":"T","body":"B","sound":"default"}` | CodoMessage(title:"T", body:"B", sound:"default") |
| decode minimal | `{"title":"T"}` | CodoMessage(title:"T", body:nil, sound:nil) |
| decode missing title | `{"body":"B"}` | DecodingError |
| decode empty string | `""` | error |
| decode garbage | `not json` | error |
| encode response ok | CodoResponse(ok:true) | `{"ok":true}` |
| encode response error | CodoResponse(ok:false, error:"msg") | `{"ok":false,"error":"msg"}` |

**CLIClient (stdin parsing)**:
| Test | Stdin | Expected |
|------|-------|----------|
| valid JSON | `{"title":"T"}\n` | parsed CodoMessage |
| empty stdin | `` | error: empty input |
| oversized payload | 64KB+ | error: payload too large |
| JSON without newline | `{"title":"T"}` | still parsed (newline optional in stdin) |

**SocketServer + CLIClient (in-memory roundtrip)**:
| Test | Scenario | Expected |
|------|----------|----------|
| happy path | client sends valid msg, mock handler returns ok | client receives `ok:true` |
| invalid json | client sends garbage | client receives `ok:false, error:"invalid json"` |
| missing title | client sends `{"body":"B"}` | client receives `ok:false, error:"title is required"` |
| server not running | client connects to nonexistent socket | exit code 2 |

> Socket tests use a temp directory (`FileManager.default.temporaryDirectory`) for the `.sock` file, not `~/.codo/`. This avoids interfering with a running daemon.

## L2 — Lint

SwiftLint in strict mode. Configuration:

```yaml
# .swiftlint.yml
strict: true
opt_in_rules:
  - empty_count
  - closure_spacing
  - force_unwrapping
disabled_rules: []
excluded:
  - .build
```

Zero warnings, zero exceptions. Enforced in pre-commit hook.

## L3 — Integration Tests

Separate test target or filtered by naming convention (`*IntegrationTests`).

**Socket lifecycle**:
| Test | Scenario | Expected |
|------|----------|----------|
| stale socket cleanup | Create stale `.sock` file, start server | Server binds successfully |
| concurrent clients | 3 clients send simultaneously | All 3 receive correct responses |
| client timeout | Server delays response > 5s | Client reports timeout, exit code 3 |

> Integration tests start a real `SocketServer` on a temp socket and exercise the full CodoCore stack. They do NOT test `UNUserNotificationCenter` (that's L4).

## L4 — E2E Checklist (Manual)

Run before each release. Requires a real Mac with the `.app` installed.

```
## Pre-release E2E Checklist

### Build
- [ ] `./scripts/build.sh` succeeds without errors
- [ ] `.build/Codo.app` exists with correct bundle structure
- [ ] `codesign -v .build/Codo.app` passes
- [ ] `CFBundleIdentifier` in Info.plist matches "dev.nocoo.codo"

### Install
- [ ] `cp -r .build/Codo.app /Applications/Codo.app` succeeds
- [ ] `ln -sf /Applications/Codo.app/Contents/MacOS/Codo /usr/local/bin/codo`
- [ ] `codo --version` prints correct version

### Daemon
- [ ] `open /Applications/Codo.app` — bell icon appears in menubar
- [ ] No Dock icon visible
- [ ] Right-click menu shows: version label, Launch at Login, Quit
- [ ] `~/.codo/codo.sock` exists with mode 0600
- [ ] `~/.codo/` directory has mode 0700

### Notification Permission
- [ ] First launch: macOS shows notification permission prompt
- [ ] After granting: System Settings > Notifications > Codo shows "Allow"

### Toast
- [ ] `echo '{"title":"Hello"}' | codo` → toast appears, exit code 0
- [ ] `echo '{"title":"T","body":"B","sound":"default"}' | codo` → toast with sound
- [ ] `echo '{"title":"T","sound":"none"}' | codo` → toast without sound

### Error Handling
- [ ] `echo '{"bad json' | codo` → stderr error, exit code 1
- [ ] `echo '{"body":"no title"}' | codo` → stderr error, exit code 1
- [ ] Quit daemon → `echo '{"title":"T"}' | codo` → "daemon not running", exit code 2

### Lifecycle
- [ ] Quit via menu → socket file cleaned up
- [ ] Start second instance → error message, exits
- [ ] Kill -9 existing → restart succeeds (stale socket cleaned)
- [ ] Launch at Login toggle → verify in System Settings > Login Items
```

## Git Hooks

### pre-commit

```bash
#!/bin/bash
set -euo pipefail

# L2: Lint
swiftlint lint --strict --quiet

# L1: Unit tests
swift test --filter "^(?!.*Integration).*$" 2>&1
```

### pre-push

```bash
#!/bin/bash
set -euo pipefail

# L1 + L2 (redundant but safe)
swiftlint lint --strict --quiet
swift test 2>&1
```

Pre-push runs ALL tests including integration tests.

## Coverage

Target: **90%+ on CodoCore**. The executable target (`Codo`) is a thin shell and is not expected to have automated test coverage — it's verified by L4.

Measure with:
```bash
swift test --enable-code-coverage
xcrun llvm-cov report .build/debug/CodoPackageTests.xctest/Contents/MacOS/CodoPackageTests \
  --instr-profile .build/debug/codecov/default.profdata \
  --sources Sources/CodoCore/
```

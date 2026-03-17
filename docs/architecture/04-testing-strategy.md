# 04 - Testing Strategy

> Four-layer testing for a two-layer system (Swift daemon + TypeScript CLI).

## Four Layers

| Layer | What | When | Tool |
|-------|------|------|------|
| **L1 — Unit Tests** | Swift: message codec, socket roundtrip. TS: arg parsing, JSON construction | pre-commit | `swift test` + `bun test` |
| **L2 — Lint** | Swift: SwiftLint strict. TS: Biome | pre-commit | `swiftlint` + `bunx biome check` |
| **L3 — Integration** | Full socket roundtrip: TS CLI → UDS → Swift server → response | pre-push | Script: start server, run CLI, assert |
| **L4 — E2E Checklist** | `.app` bundle: install, permission, toast display | Manual (pre-release) | Human |

### Why L4 is manual

Toast display depends on macOS notification permission, code signature, and bundle identity. These cannot be reliably automated. A checklist is more honest than a flaky test.

## L1 — Swift Unit Tests

Target: `CodoCoreTests`, depends on `CodoCore` only.

**MessageCodec**:
| Test | Input | Expected |
|------|-------|----------|
| decode full message | `{"title":"T","body":"B","sound":"default"}` | CodoMessage(title, body, sound) |
| decode minimal | `{"title":"T"}` | title only, others nil |
| decode missing title | `{"body":"B"}` | DecodingError |
| decode empty | `""` | error |
| decode garbage | `not json` | error |
| encode response ok | CodoResponse(ok:true) | `{"ok":true}` |
| encode response error | CodoResponse(ok:false, error:"msg") | correct JSON |

**SocketServer** (with mock handler, temp socket dir):
| Test | Scenario | Expected |
|------|----------|----------|
| happy path | valid message, handler returns ok | `ok:true` response |
| invalid json | garbage bytes | `ok:false, "invalid json"` |
| missing title | `{"body":"B"}` | `ok:false, "title is required"` |
| stale socket | create stale file, start server | binds successfully |
| concurrent clients | 3 simultaneous | all get correct response |

**NotificationService** (protocol mock):
| Test | Scenario | Expected |
|------|----------|----------|
| available + granted | mock returns success | ok:true |
| unavailable (no bundle) | `isAvailable=false` | ok:false, unavailable |
| permission denied | mock returns denied | ok:false, denied |

> Socket tests use temp directory for `.sock` file, never `~/.codo/`.

## L1 — TypeScript Unit Tests

File: `cli/codo.test.ts`, run with `bun test`.

**Arg parsing**:
| Test | Args | Expected |
|------|------|----------|
| title only | `["Build Done"]` | `{title:"Build Done"}` |
| title + body | `["Build Done", "Passed"]` | `{title:..., body:...}` |
| with --silent | `["Done", "--silent"]` | `{..., sound:"none"}` |
| no args | `[]` | error/usage |
| --help | `["--help"]` | print help |
| --version | `["--version"]` | print version |

**JSON construction**:
| Test | Input | Expected |
|------|-------|----------|
| minimal | `{title:"T"}` | valid JSON with title |
| full | `{title:"T",body:"B",sound:"default"}` | all fields |
| stdin JSON | piped `{"title":"T"}` | parsed correctly |

## L2 — Lint

### Swift

```yaml
# .swiftlint.yml
strict: true
opt_in_rules:
  - empty_count
  - closure_spacing
  - force_unwrapping
excluded:
  - .build
```

### TypeScript

```json
// cli/biome.json
{ "linter": { "rules": { "recommended": true } } }
```

## L3 — Integration Tests

Script-based: spin up a real `SocketServer` on a temp socket, call from TS CLI, assert response.

| Test | Scenario | Expected |
|------|----------|----------|
| CLI → server happy path | `codo.ts` sends to temp socket, mock notification handler | exit 0, stdout ok |
| server not running | CLI tries to connect, no server | exit 2, stderr "not running" |
| client timeout | server delays > 5s | exit 3, stderr timeout |

## L4 — E2E Checklist

```markdown
## Pre-release E2E Checklist

### Build
- [ ] `./scripts/build.sh` succeeds
- [ ] `codesign -v .build/Codo.app` passes

### Install
- [ ] `cp -r .build/Codo.app /Applications/Codo.app`
- [ ] `ln -sf $(pwd)/cli/codo.ts /usr/local/bin/codo`
- [ ] `codo --version` prints version

### Daemon
- [ ] `open /Applications/Codo.app` → bell icon in menubar
- [ ] No Dock icon
- [ ] Right-click: version, Launch at Login, Quit
- [ ] `~/.codo/codo.sock` exists (mode 0600)

### Permission
- [ ] First launch: permission prompt appears
- [ ] System Settings > Notifications > Codo shows Allow

### Toast
- [ ] `codo "Hello"` → toast, exit 0
- [ ] `codo "Title" "Body"` → toast with body
- [ ] `codo "Silent" --silent` → toast without sound

### Errors
- [ ] `echo '{"bad' | codo` → exit 1
- [ ] Quit daemon → `codo "Test"` → "not running", exit 2

### Lifecycle
- [ ] Quit → socket file removed
- [ ] Second instance → error, exits
- [ ] kill -9 → restart cleans stale socket
- [ ] Launch at Login toggle works
```

## Git Hooks

### pre-commit

```bash
#!/bin/bash
set -euo pipefail

# L2: Lint
swiftlint lint --strict --quiet
cd cli && bunx biome check . && cd ..

# L1: Unit tests
swift test
cd cli && bun test && cd ..
```

### pre-push

```bash
#!/bin/bash
set -euo pipefail

# L1 + L2
swiftlint lint --strict --quiet
swift test
cd cli && bunx biome check . && bun test && cd ..

# L3: Integration
./scripts/integration-test.sh
```

## Coverage

Target: **90%+ on CodoCore**, measured via `swift test --enable-code-coverage`.

TS CLI: `bun test --coverage`, target 90%+.

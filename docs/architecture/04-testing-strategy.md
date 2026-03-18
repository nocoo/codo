# 04 - Testing Strategy

> Four-layer testing for a two-layer system (Swift daemon + TypeScript CLI).

## Four Layers

| Layer | What | When | Tool |
|-------|------|------|------|
| **L1 — Unit Tests** | Swift: message codec, socket roundtrip, notification service. TS: arg parsing, JSON construction, template expansion | pre-commit | `swift test` + `bun test` |
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
| decode all fields | `{"title":"T","subtitle":"S","threadId":"t1"}` | All fields populated |
| decode minimal | `{"title":"T"}` | title only, others nil |
| decode missing title | `{"body":"B"}` | DecodingError |
| decode empty | `""` | error |
| decode garbage | `not json` | error |
| encode response ok | CodoResponse(ok:true) | `{"ok":true}` |
| encode response error | CodoResponse(ok:false, error:"msg") | correct JSON |
| encode with subtitle/threadId | CodoMessage with all fields | correct JSON |
| backward compat | JSON without subtitle/threadId | decodes, new fields nil |

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
| explicit sound | `sound: "none"` | effectiveSound == "none" |
| subtitle + threadId | message with all fields | passed through to provider |
| permission granted | requestPermission() | true |
| permission denied | requestPermission() | false |
| permission unavailable | isAvailable=false | false |

> Socket tests use temp directory for `.sock` file, never `~/.codo/`.

## L1 — TypeScript Unit Tests

File: `cli/codo.test.ts`, run with `bun test`.

**Arg parsing**:
| Test | Args | Expected |
|------|------|----------|
| title only | `["Build Done"]` | `{title:"Build Done"}` |
| title + body | `["Build Done", "Passed"]` | `{title:..., body:...}` |
| with --silent | `["Done", "--silent"]` | `{..., sound:"none"}` |
| --template success | `["T", "--template", "success"]` | subtitle + sound from template |
| --template unknown | `["T", "--template", "bad"]` | error: "unknown template: bad" |
| --subtitle flag | `["T", "--subtitle", "text"]` | subtitle set |
| --thread flag | `["T", "--thread", "my-id"]` | threadId set |
| --silent + template | `["T", "--template", "success", "--silent"]` | sound:"none" overrides template |
| flag missing value | `["T", "--template"]` | error: "--template requires a value" |
| flag-as-value | `["T", "--thread", "--silent"]` | error: "--thread requires a value" |
| no args | `[]` | error/usage |
| --help | `["--help"]` | print help |
| --version | `["--version"]` | print version |
| args + stdin | args=`["B"]`, stdin=`{"title":"A"}` | args win, title="B" |
| empty stdin no args | stdin empty, no args | error/usage |

**Template expansion (applyTemplate)**:
| Test | Input | Expected |
|------|-------|----------|
| all 8 templates | each template name | correct subtitle + sound |
| unknown template | `"nonexistent"` | error |
| explicit subtitle wins | message with subtitle + template | message subtitle preserved |
| template never sets threadId | any template | threadId remains nil |

**Stdin parsing**:
| Test | Input | Expected |
|------|-------|----------|
| subtitle + threadId | `{"title":"T","subtitle":"S","threadId":"t"}` | fields set |
| empty subtitle | `{"title":"T","subtitle":"  "}` | subtitle omitted |
| template key ignored | `{"title":"T","template":"success"}` | no expansion |

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

Script-based: spin up a real Swift `CodoTestServer` on a temp socket, call from TS CLI, assert response. The test server logs all received messages to `$SOCK_DIR/messages.log` for field verification.

| Test | Scenario | Expected |
|------|----------|----------|
| --help | help flag | exit 0, usage text |
| --version | version flag | exit 0, version string |
| no daemon | CLI tries to connect, no server | exit 2, "daemon not running" |
| title only | send title to server | exit 0, no stdout |
| title + body | send title and body | exit 0, no stdout |
| stdin json | pipe JSON to CLI | exit 0, no stdout |
| --silent | send with silent flag | exit 0, no stdout |
| daemon error | title="fail-me" triggers error | exit 1, "test error" |
| invalid stdin json | malformed JSON pipe | exit 1, "invalid json" |
| empty title | empty string as title | exit 1, "title is required" |
| concurrent clients | 3 simultaneous + follow-up | server survives |
| --template list | list templates | exit 0, template names in output |
| --template success | send with template | server log shows subtitle |
| subtitle+threadId stdin | pipe JSON with new fields | server log shows fields |
| --thread flag | send with thread flag | server log shows threadId |
| --silent + template | silent overrides template sound | server log shows sound:"none" |

## L4 — E2E Checklist

```markdown
## Pre-release E2E Checklist

### Build
- [ ] `./scripts/build.sh` succeeds
- [ ] `codesign -v .build/Codo.app` passes

### Install
- [ ] `./scripts/install.sh` completes
- [ ] `~/.codo/codo.ts` exists and is executable
- [ ] `/usr/local/bin/codo` → `~/.codo/codo.ts`
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
- [ ] `codo "Build Done" --template success` → toast with ✅ Success subtitle
- [ ] `codo "Error" --template error` → toast with ❌ Error subtitle
- [ ] `codo "Step 1" --template progress --thread task` → silent toast
- [ ] `codo "Step 2" --template progress --thread task` → groups with above
- [ ] Notification banner shows app icon (hummingbird)

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

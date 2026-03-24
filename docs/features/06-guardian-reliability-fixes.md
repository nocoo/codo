# Guardian Reliability Fixes

Investigation on 2026-03-25 revealed Guardian has been non-functional since ~2026-03-20. This doc captures the root cause chain and fix plan.

## Root Cause Chain

```
① Provider misconfiguration
   CODO_PROVIDER=custom, CODO_SDK_TYPE=openai, CODO_BASE_URL=api.openai.com/v1
   But API key (sk-cp-...) belongs to MiniMax (Anthropic SDK protocol)
   ↓
② All LLM requests fail (401 or 30s timeout abort) — 300+ occurrences
   ↓
③ Fallback path crash
   fallback.ts:truncate() receives object instead of string
   → "s.slice is not a function" — 1156 occurrences
   ↓
④ Guardian process crash (unhandled exception)
   4 rapid failures (failureCount > maxFailures=3) → CrashLoopBreaker.tripped
   → onDisabled callback → guardianEnabled = false
   ↓
⑤ Guardian permanently disabled
   Codo.app reads guardianEnabled=0 from suite "ai.hexly.codo" on next launch
   → spawnGuardianIfNeeded() early-returns, no guardian spawned
   ↓
⑥ Orphan process accumulation (7 zombie guardians, all PPID=1)
   Previous Codo.app restarts left old guardians alive
   App cold-start has no cleanup logic for stale guardian processes
```

## Fixes

### Fix 1: Eliminate unsafe `as string` casts on HookEvent fields

**Files**: `guardian/fallback.ts`, `guardian/llm.ts`

**Problem**: `HookEvent` has `[key: string]: unknown` index signature. Multiple call sites cast fields like `event.tool_response as string` without runtime checks. When the actual Claude Code payload delivers an object (e.g. `tool_response` as JSON object), the cast is a no-op at runtime:

- **fallback.ts L64**: `truncate(event.tool_response as string, 100)` → object hits `.slice()` → crash (1156 occurrences in log)
- **llm.ts L150**: `const response = event.tool_response as string` → `response.length` / `response.slice(0, 500)` → same crash class, just on the LLM path instead of fallback
- **llm.ts L162**: `event.error as string` → same risk
- **llm.ts L126**: `event.last_assistant_message as string` — used inside template literal so won't crash, but produces `[object Object]` garbage in the LLM prompt

**Changes**:

#### 1a. Harden `truncate()` in fallback.ts

```typescript
// Before
function truncate(
  s: string | undefined | null,
  max: number,
): string | undefined {
  if (!s) return undefined;
  return s.length <= max ? s : `${s.slice(0, max)}...`;
}

// After
function truncate(
  s: unknown,
  max: number,
): string | undefined {
  if (typeof s !== "string") return undefined;
  return s.length <= max ? s : `${s.slice(0, max)}...`;
}
```

Remove unsafe casts in fallback.ts callers — with `truncate` accepting `unknown`, the casts are unnecessary:

| Line | Current | Fixed |
|------|---------|-------|
| L36 | `truncate(event.last_assistant_message as string, 100)` | `truncate(event.last_assistant_message, 100)` |
| L64 | `truncate(event.tool_response as string, 100)` | `truncate(event.tool_response, 100)` |
| L76 | `truncate(event.error as string, 100)` | `truncate(event.error, 100)` |

#### 1b. Add `stringify()` helper for llm.ts

llm.ts `buildUserMessage()` needs the value as a string for the LLM prompt (not just truncated). Add a shared coercion helper and use it:

```typescript
// guardian/llm.ts — new helper
function stringify(v: unknown, max: number): string {
  if (typeof v === "string") return v.length <= max ? v : `${v.slice(0, max)}...`;
  if (v == null) return "";
  try {
    const s = JSON.stringify(v);
    return s.length <= max ? s : `${s.slice(0, max)}...`;
  } catch {
    return String(v).slice(0, max);
  }
}
```

Fix unsafe casts in `buildUserMessage()`:

| Line | Current | Fixed |
|------|---------|-------|
| L126 | `event.last_assistant_message as string` | `stringify(event.last_assistant_message, 500)` |
| L132 | `event.title as string` | `String(event.title)` |
| L133 | `event.message as string` | `String(event.message)` |
| L141 | `event.tool_name as string` | `String(event.tool_name)` |
| L150-153 | `const response = event.tool_response as string; response.length > 500 ? response.slice(0, 500)...` | `stringify(event.tool_response, 500)` |
| L159 | `event.tool_name as string` | `String(event.tool_name)` |
| L162 | `event.error as string` | `stringify(event.error, 500)` |
| L167 | `event.model as string` | `String(event.model)` |

**Tests**:
- `guardian/fallback.test.ts`: truncate with object, undefined, null, string, number inputs
- `guardian/llm.test.ts`: buildUserMessage with object-typed tool_response and error fields

---

### Fix 2: Kill orphaned guardians on cold start only

**Files**: `Sources/CodoCore/GuardianProcess.swift`, `Sources/Codo/AppDelegate.swift`

**Problem**: If Codo.app is force-killed or crashes, child guardian processes become orphans (PPID=1). On next launch, `spawnGuardianIfNeeded()` creates a new guardian without cleaning up the old ones.

**Constraint**: `spawnGuardianIfNeeded()` is called from three sites:
1. `applicationDidFinishLaunching` — cold start (needs orphan cleanup)
2. `toggleGuardian` — user toggling the menu switch (should NOT kill other guardians)
3. `settingsDidSave` — config change (calls `guardian?.stop()` first, should NOT kill other guardians)

Only the cold-start path needs orphan cleanup. Toggle and settings-save already call `stop()` on the tracked process.

**Change**:

Add a static cleanup method that kills orphans whose command line contains the full `guardianPath` (absolute path, so different projects won't collide), and call it only from `applicationDidFinishLaunching`, not from `spawnGuardianIfNeeded()`:

```swift
// Sources/CodoCore/GuardianProcess.swift

/// Kill orphaned guardian processes from previous Codo sessions.
///
/// Uses `pgrep -f` to find processes whose command line contains `guardianPath`.
/// Since `guardianPath` is an absolute path (e.g. /Users/.../codo/guardian/main.ts),
/// this won't match guardians from a different project checkout.
/// Then filters to PPID == 1 (adopted by launchd = true orphans), so it won't
/// kill a guardian actively managed by a running Codo instance.
public static func killOrphans(guardianPath: String) {
    // pgrep -f returns PIDs matching the command line pattern
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", guardianPath]
    let pipe = Pipe()
    pgrep.standardOutput = pipe
    pgrep.standardError = FileHandle.nullDevice
    try? pgrep.run()
    pgrep.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return }

    let pids = output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    let myPid = ProcessInfo.processInfo.processIdentifier

    for pid in pids where pid != myPid {
        // Check if this process is an orphan (PPID == 1)
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", "\(pid)", "-o", "ppid="]
        let psPipe = Pipe()
        ps.standardOutput = psPipe
        ps.standardError = FileHandle.nullDevice
        try? ps.run()
        ps.waitUntilExit()

        let psData = psPipe.fileHandleForReading.readDataToEndOfFile()
        if let ppidStr = String(data: psData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let ppid = Int32(ppidStr), ppid == 1 {
            kill(pid, SIGTERM)
        }
    }
}
```

**Call site**: `AppDelegate.applicationDidFinishLaunching`, before `spawnGuardianIfNeeded()`:

```swift
// Clean up orphaned guardians from previous sessions (cold start only)
if let guardianPath = GuardianPathResolver.resolve() {
    GuardianProcess.killOrphans(guardianPath: guardianPath)
}
spawnGuardianIfNeeded()
```

**NOT** inside `spawnGuardianIfNeeded()` — that method is also called from `toggleGuardian` and `settingsDidSave`.

**Test**: Unit test verifying `killOrphans` only targets PPID=1 processes (mock pgrep/ps output).

---

### Fix 3: Fix provider configuration (manual step)

**Problem**: Settings in UserDefaults suite `ai.hexly.codo` have wrong provider config. The MiniMax API key is being sent to `api.openai.com/v1` with OpenAI SDK.

**Option A — Use built-in MiniMax provider** (recommended):

```bash
defaults write ai.hexly.codo guardianProvider minimax
defaults write ai.hexly.codo guardianModel MiniMax-M2.7
defaults delete ai.hexly.codo guardianBaseURL
defaults delete ai.hexly.codo guardianSdkType
```

The built-in `minimax` provider auto-fills `baseURL=https://api.minimaxi.com/anthropic` and `sdkType=anthropic`.

**Option B — Use custom provider**:

```bash
defaults write ai.hexly.codo guardianProvider custom
defaults write ai.hexly.codo guardianSdkType anthropic
defaults write ai.hexly.codo guardianBaseURL "https://api.minimaxi.com/anthropic"
defaults write ai.hexly.codo guardianModel MiniMax-M2.7
```

**Re-enable guardian** (was disabled by crash breaker):

```bash
defaults write ai.hexly.codo guardianEnabled -bool true
```

---

### Fix 4: Clean up current zombie processes (one-time manual step)

The 7 orphaned guardians predate the killOrphans fix. Kill only PPID=1 orphans.

Note: The actual guardian path in the process command line depends on how Codo.app resolved it via `GuardianPathResolver` — it could be a bundle Resources path or a dev checkout path. Use a broad `guardian/main.ts` match here but filter strictly by PPID=1, which is safe for a one-time manual cleanup:

```bash
# Kill orphaned guardian processes (PPID=1 only)
pgrep -f "guardian/main.ts" | while read pid; do
  ppid=$(ps -p "$pid" -o ppid= | tr -d ' ')
  cmd=$(ps -p "$pid" -o args= | head -c 120)
  if [ "$ppid" = "1" ]; then
    echo "Killing orphan PID=$pid cmd=$cmd"
    kill "$pid"
  else
    echo "Skipping PID=$pid PPID=$ppid (has live parent)"
  fi
done
```

---

## Atomic Commits

| # | Scope | Description |
|---|-------|-------------|
| 1 | `guardian/fallback.ts` | Harden truncate to accept unknown; remove unsafe `as string` casts |
| 2 | `guardian/llm.ts` | Add stringify helper; replace all unsafe `as string` casts in buildUserMessage |
| 3 | `guardian/fallback.test.ts`, `guardian/llm.test.ts` | Tests for truncate edge cases and buildUserMessage with object payloads |
| 4 | `Sources/CodoCore/GuardianProcess.swift` | Add killOrphans static method (PPID=1 filter + absolute path substring match) |
| 5 | `Sources/Codo/AppDelegate.swift` | Call killOrphans in applicationDidFinishLaunching (cold start only) |
| 6 | Manual | Fix provider config + re-enable guardian + kill zombies |

## Verification

After all fixes applied:

```bash
# 1. Run Fix 4 script above to clean current orphans

# 2. Restart Codo.app (killOrphans runs automatically on cold start now)
pkill -f "Codo.app/Contents/MacOS/Codo"; sleep 1
open .build/release/Codo.app

# 3. Verify exactly one guardian alive, parented by Codo.app
#    (use broad match — the actual path may be bundle or dev layout)
pgrep -f "guardian/main.ts" | while read pid; do
  ppid=$(ps -p "$pid" -o ppid= | tr -d ' ')
  cmd=$(ps -p "$pid" -o args= | head -c 120)
  echo "PID=$pid PPID=$ppid cmd=$cmd"
done
# Expected: single PID with PPID = Codo.app's PID

# 4. Check guardian log for successful LLM connection
tail -f ~/.codo/guardian.log

# 5. Trigger a test hook event
echo '{"title":"Fix verified","body":"Guardian is back online"}' | bun ~/.codo/codo.ts
```

# Changelog

## v0.2.0

### Guardian Reliability

- **Eliminate unsafe `as string` casts** — Harden `truncate()` in fallback.ts, add `stringify()` helper in llm.ts, and remove all unsafe casts on `HookEvent` fields (`tool_response`, `error`, `last_assistant_message`, `title`, `model`) across fallback, LLM, and state layers
- **Fix state.ts crash path** — `isGenericTask()` and `truncate()` in state.ts now accept `unknown`, preventing `TypeError: message.trim is not a function` when hook payloads deliver objects instead of strings
- **Kill orphaned guardians on cold start** — Add `GuardianProcess.killOrphans()` that finds PPID=1 orphans matching the absolute guardian path and sends SIGTERM; called from `applicationDidFinishLaunching` only
- **Lifecycle race condition fix** — Add `lifecycleQueue` (serial DispatchQueue) to `GuardianProcess` protecting all mutable state (`process`, `intentionalStop`, pipes) from concurrent access
- **Stop-before-spawn guard** — `spawnGuardianIfNeeded()` now stops any existing guardian before creating a new one; `settingsDidSave()` simplified to just call `spawnGuardianIfNeeded()`

### Dashboard & UI

- **SwiftUI Dashboard** — Full project dashboard with data layer, keyboard shortcuts, animations, and polished empty states
- **Banner notification redesign** — Top-position glass-style banner with project badge, hover interaction, pause timer, and close button
- **Project badge** — Stable color hash capsule with single-line header layout
- **Project logo storage** — SHA256-based filename storage with proper cleanup
- **Settings migration** — Replace AppKit SettingsWindow with SwiftUI SettingsView

### Infrastructure

- **Structured logging** — New logger module with JSON structured output, diagnostic logging in classifier, LLM, state, and CLI layers
- **Hook integration** — Claude Code hook script with integration tests, persistent hooks.log, and PIPESTATUS fix
- **Stability fixes** — Ignore SIGPIPE, disable automatic termination, file-based API key storage, menubar icon-only status item

### Tests

- Regression tests for object-typed HookEvent fields in state.test.ts and main.test.ts
- killOrphans smoke tests in GuardianProcessTests.swift
- Edge case tests for truncate and buildUserMessage with object payloads

## v0.1.1

### Features

- **AI Guardian** — LLM-powered notification intelligence that classifies hook events, generates Chinese notification summaries, and suppresses noise
- **Provider registry** — Built-in support for Anthropic, MiniMax, GLM (Zhipu), and AIHubMix with auto-configured base URLs and SDK types
- **Notification templates** — `--template success|error|warning|info|progress|question|deploy|review` for styled notifications with subtitle, sound, and thread grouping
- **Hook event forwarding** — `--hook stop|notification|post-tool-use|...` to pipe Claude Code hook events through Guardian
- **Settings window** — macOS native settings UI for provider selection, API key, model, and Guardian toggle
- **Guardian crash recovery** — Auto-restart with crash loop breaker and stability timer

### Fixes

- Fix duplicate `/v1` in Anthropic SDK provider base URLs causing 404 errors
- Increase LLM timeout from 10s to 30s for slower providers
- Capture Guardian stderr to `~/.codo/guardian.log` for runtime diagnostics
- Add Edit menu to enable paste (Cmd+V) in settings text fields
- Restart Guardian automatically after settings save
- Walk up directory tree to find `guardian/main.ts` for all SPM build layouts
- Require Chinese output in Guardian notification prompt and tool descriptions

### Infrastructure

- Four-layer test suite: 115 Swift + 76 CLI + 95 Guardian unit tests, SwiftLint + Biome lint, 21 integration tests
- Husky git hooks: pre-commit (UT + lint), pre-push (UT + lint + integration)
- Serial queue for Guardian readline to prevent state mutation races

## v0.1.0

Initial MVP release.

- macOS menu bar daemon with Unix domain socket IPC
- TypeScript CLI client (`bun cli/codo.ts`)
- `UNUserNotificationCenter` notification delivery
- `CodoMessage` wire format with title, body, sound

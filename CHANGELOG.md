# Changelog

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

# Codo

macOS menubar daemon + CLI for displaying system toast notifications. Designed as a notification bridge for Claude Code hooks.

```bash
# From any Claude Code hook:
codo "Build Done" "All 42 tests passed"

# Or via stdin JSON:
echo '{"title":"Build Done","body":"All tests passed"}' | codo
```

## Architecture

Two layers: **Swift menubar app** (daemon, listens on Unix Domain Socket, shows toast) + **TypeScript CLI** (Bun script, sends messages to daemon).

## Development

### Prerequisites

- **macOS 14+** (Sonoma)
- **Swift 5.10+** (`swift --version`)
- **Bun** (`bun --version`) — CLI runtime and TS test runner
- **SwiftLint** (`brew install swiftlint`)

### Setup

```bash
# Install dependencies and git hooks
bun install
```

This runs `husky` via the `prepare` script, which sets up `.husky/` as the git hooks directory.

### Git Hooks

| Hook | Stage | What runs |
|------|-------|-----------|
| **pre-commit** | L1 | `swift test` + `bun test` (unit tests only — fast feedback) |
| **pre-push** | L1+L2+L3 | Unit tests + SwiftLint strict + Biome lint + integration tests |

Hooks **cannot be skipped** — this is by design. Every commit must pass unit tests.

### Running Tests Manually

```bash
# L1: Swift unit tests (34 tests)
swift test

# L1: TypeScript unit tests (26 tests)
cd cli && bun test

# L2: Swift lint
swiftlint lint --strict --quiet

# L2: TypeScript lint
cd cli && bunx biome check .

# L3: Integration tests (8 tests)
./scripts/integration-test.sh

# Swift coverage report (target: 90%+ on CodoCore)
swift test --enable-code-coverage
xcrun llvm-cov report \
  .build/debug/CodoPackageTests.xctest/Contents/MacOS/CodoPackageTests \
  --instr-profile=.build/debug/codecov/default.profdata \
  --sources Sources/CodoCore/
```

### Coverage

| Target | Current | Goal |
|--------|---------|------|
| CodoCore (testable) | 91% | ≥ 90% |
| CLI (parseArgs/parseStdin) | 100% | — |

`SystemNotificationProvider` is excluded from coverage — it requires a real `.app` bundle with `UNUserNotificationCenter` and is tested via L4 E2E manual checklist.

### Build & Install

```bash
# Build signed .app bundle
./scripts/build.sh

# Install to ~/Applications + symlink CLI to /usr/local/bin
./scripts/install.sh
```

## Docs

See [docs/](docs/) for design documents:

- [Architecture](docs/architecture/) — System design, IPC protocol, build, testing, MVP plan

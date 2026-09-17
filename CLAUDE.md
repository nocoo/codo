# Codo

macOS menubar notification daemon with a Swift app, Bun CLI and optional Guardian subprocess.
Profile: native-hybrid, with Swift and TypeScript lanes.
Direction: [system design](docs/architecture/01-system-design.md). Frameworks must not rewrite this file.

## Sources of Truth

This file is the contract; hooks, CI and configuration enforce it. Raise weaker enforcement instead of lowering this contract.

| Fact | Where |
|---|---|
| Human docs | [README.md](README.md), `docs/architecture/`, `docs/features/` |
| Version | Root/CLI/Guardian manifests, CLI `VERSION`, `CodoInfo.version`, `Resources/Info.plist`; synchronize for an authorized release |
| Enforcement | `.husky/`, `.github/workflows/ci.yml`, native and Bun tests |
| Secrets | macOS Keychain; app injects Guardian variables such as `CODO_PROVIDER` and `CODO_API_KEY` |
| Machine rules / accidents | Global `AGENTS.md` and `rules/`; [Retrospective.md](Retrospective.md) |

## Project Invariants

- The app is `LSUIElement` menubar-only. CLI JSON messages use the Unix socket `~/.codo/codo.sock`; Guardian uses stdin/stdout JSON and stderr logging under `~/.codo/`.
- Installer copies CLI and hook files to `~/.codo/`; they are not symlinks. Recopy/reinstall after an authorized CLI/hook deployment.
- Keep API keys in Keychain. Guardian decides notification suppression/content, never executes terminal commands; failure falls back to basic notification rules.
- Tests use injected preferences, fake model providers and a temporary home/socket. Never point them at the user's live daemon, database or credentials.
- Preserve protocol fields even where current custom banners do not implement sound/thread grouping. Do not claim OS notification behavior the app does not provide.
- App packaging currently omits `guardian/` and dependencies; installed `~/Applications/Codo.app` cannot rely on the repo-layout Guardian resolver. Track this as a packaging gap, not a reason to mutate the live installation during tests.

## Stack / Layout

| Component | Choice |
|---|---|
| Native | macOS 14+, Swift package 5.10, SwiftUI/AppKit, SQLite/Keychain |
| Toolchain | Xcode with Swift Testing, SwiftLint, Bun; CI Bun 1.4.2 |
| `Sources/Codo/`, `Sources/CodoCore/` | App, IPC, storage and Guardian management |
| `Sources/CodoTestServer/`, `Tests/` | Isolated socket host and native tests |
| `cli/`, `guardian/`, `hooks/`, `scripts/` | Bun processes, hook integration, build/install/checks |

## Commands

Run each line independently from the root. Install root hook tooling and Guardian dependencies separately; CLI has no dependency lockfile. Unit and IPC tests need no real model key. Use full Xcode: if the machine selects Command Line Tools, prefix the check/commit/push with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` so SwiftUI macros resolve.

```bash
bun install --frozen-lockfile
bun install --cwd guardian --frozen-lockfile
swift build
swift test
(cd cli && bun test)
(cd guardian && bun test)
swiftlint lint --strict --quiet
(cd cli && ../guardian/node_modules/.bin/biome check --error-on-warnings .)
(cd guardian && ./node_modules/.bin/biome check --error-on-warnings .)
./scripts/integration-test.sh
```

`swift build` creates executables; `./scripts/build.sh` additionally assembles/signs `.build/release/Codo.app` using full Xcode and the configured Apple Development identity. Packaging/install and native UI checks are explicit manual operations, not prerequisites for a documentation edit.

## Verification

6DQ = L1/L2/L3 + G1/G2 + D1. Status: `enforced`, `planned`, `manual`, `N/A`.

| Dimension | Required proof | Status | Current enforcement / gap |
|---|---|---|---|
| L1 Swift | Measurable statements/branches/functions/lines each ≥95%; no skipped/focused tests | planned | Commit/CI run native tests; CI enables coverage but has no percentage gate or complete four-metric report |
| L1 TypeScript | Statements, branches, functions and lines each ≥95%; no `.skip` / `.only` | planned | Commit/CI run CLI/Guardian Bun tests without coverage thresholds |
| L2 IPC | Real Swift server/Bun client protocol and failure-path integration | enforced | Pre-push requires `scripts/integration-test.sh`, builds `CodoTestServer` and uses a temporary socket; no application HTTP API exists |
| L3 native UI | Menubar, banner and Guardian user journeys | manual | `scripts/e2e-test.sh` is an interactive checklist that restarts Codo; run only for explicit desktop validation |
| G1 Swift | Strict check-only lint and successful compilation | enforced | Local SwiftLint strict and native test build; CI native test compilation |
| G1 TypeScript | Strict types and check-only lint, zero errors/warnings | planned | Local/CI Biome runs, but Guardian has no tsconfig and CI disables typechecking |
| G2 security | Secret and dependency scans; missing scanner fails | enforced | CI scans full Git history and `guardian/bun.lock`; local hooks omit G2 |
| D1 isolation | Per-run local socket/data/preferences and guarded cleanup | planned | Integration allocates fake home directories but shares `/tmp/codo-integ-stderr.txt`; complete per-run/cleanup guarantees are missing |
| Build / packaging | Intended app bundle and Guardian resources | manual | `scripts/build.sh`; installed Guardian path remains incomplete |
| Docs | Native, IPC and installed-copy behavior reviewed | manual | Architecture/features and README |

| Hook | Current behavior | Required follow-up |
|---|---|---|
| pre-commit | Working-tree Swift/CLI/Guardian tests, SwiftLint and Biome | G1+L1 coverage on index snapshot, <30s |
| pre-push | Repeats tests/lint, then IPC integration | Applicable integration+G2 on stdin push refs, <3min |

Install restores Husky. Hooks are check-only; never use `--no-verify` on commits or branch pushes. CI shared workflows are pinned at `ad43150de3a2be2fa464b5cd2f921dc4fa9f8f0f`.

## Resources / Isolation

Daily app/socket/logs/database live under the machine owner's directories. IPC tests create a fresh local socket and remove only their own allocation. Use per-run preferences/databases for native tests; do not share the daily user's resources or contact real model providers. No remote `-test` infrastructure is needed.

## Operations / Release

For an authorized local install, the machine owner runs `./scripts/build.sh`, then `./scripts/install.sh` with the intended signing identity. There is no GitHub deployment automation. Keep the signature stable for permissions and account for the Guardian packaging gap.
After installation, verify the Codo/Guardian process state, socket and expected notification locally. Preserve hook exit codes before logging; installed CLI/hook copies must be refreshed after changes.

## Retrospective

Narratives remain in [Retrospective.md](Retrospective.md); keep only recurring rules here, cross-project lessons in global rules/nmem and deterministic requirements in hooks/tests.

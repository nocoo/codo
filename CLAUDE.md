# Codo

macOS menubar notification daemon for Claude Code hooks: Swift `Codo.app` + Bun CLI + Guardian subprocess.
Profile: native-hybrid
Direction: [docs/architecture/01-system-design.md](docs/architecture/01-system-design.md). Frameworks must not rewrite this file.

## Sources of Truth

This file is the **contract**. Hooks, CI, and config are **enforcement**. If they disagree, raise enforcement; never lower this file.

| Fact | Where |
|---|---|
| Agent handbook | this file |
| Human docs | README.md, `docs/architecture/*`, `docs/features/*` |
| Version | root `package.json` `"version"` (also `cli/` + `guardian/` package.json) |
| Enforcement | `.husky/*`, `.github/workflows/ci.yml` |
| Machine rules | global `AGENTS.md`, `rules/git-commit.md` |
| Accidents | [Retrospective.md](Retrospective.md) |
| Env files | omit. API keys in Keychain (`CODO_API_KEY`); never in git |

## Project Invariants

- `cli/codo.ts` and `hooks/claude-hook.sh` are **copied** to `~/.codo/` by `scripts/install.sh`, not symlinked. After editing them, recopy or install again.
- Socket `~/.codo/codo.sock`. App is `LSUIElement` menubar (no Dock). Guardian is `guardian/main.ts` stdin/stdout JSON; stderr → `~/.codo/guardian.log`.
- API keys stay in Keychain. Guardian env is injected by the app (`CODO_PROVIDER`, `CODO_API_KEY`, …).
- Integration tests use a fake `HOME` + `CodoTestServer`. Do not point them at the human `~/.codo`.
- macOS 14+, Swift 5.10, Bun, SwiftLint.

## Stack / Layout

| Component | Choice |
|---|---|
| Language | Swift 5.10 (app/core) + TypeScript (cli + guardian, Bun) |
| Package manager | SwiftPM + Bun (`cli/`, `guardian/`) |
| Runtime | macOS menubar app + Unix socket CLI |
| Lint | SwiftLint `--strict`; Biome `--error-on-warnings` on cli/guardian |
| Tests | `swift test`; `bun test` in cli + guardian; `scripts/integration-test.sh` |
| Data | local socket + logs under `~/.codo/` |

```
Sources/Codo  Sources/CodoCore  Tests/CodoCoreTests
cli/  guardian/  hooks/  scripts/
```

## Commands

```bash
bun install
swift test
cd cli && bun test
cd guardian && bun test
swiftlint lint --strict --quiet
cd cli && bunx biome check --error-on-warnings .
cd guardian && bunx biome check --error-on-warnings .
./scripts/build.sh
./scripts/install.sh
./scripts/integration-test.sh
```

## Verification

Status: `enforced` | `planned` | `manual` | `N/A`. `enforced` Evidence = hook/CI/config/script.

Org gaps: index-snapshot pre-commit; stdin-range pre-push; TS coverage thresholds; Swift coverage fail-under (CI enables coverage, no % gate); G2 on hooks.

Today: pre-commit `swift test` + cli/guardian `bun test` + SwiftLint + Biome (working tree). pre-push repeats that then `scripts/integration-test.sh`. CI: macOS `swift test --enable-code-coverage`; Ubuntu bun test + Biome + gitleaks. OSV runs with `|| true` (not a gate).

| Change | Proof | Status | Evidence |
|---|---|---|---|
| Logic Swift | `swift test` | enforced | pre-commit; CI `swift-tests` |
| Logic TS | `bun test` cli + guardian (no coverage %) | enforced | pre-commit; CI `quality` |
| IPC L2 | UDS against `CodoTestServer` + fake HOME | enforced | pre-push `integration-test.sh` |
| UI L3 | Playwright | N/A | — |
| Types / lint | SwiftLint strict + Biome 0 warning | enforced | pre-commit + CI Biome |
| G2 secrets | gitleaks | enforced | CI only (not husky) |
| G2 deps | osv cli + guardian lockfiles | planned | CI `osv-scanner … \|\| true` |
| Bundler | `scripts/build.sh` → `.build/release/Codo.app` | manual | operator |
| Docs | numbered doc if behavior changes | manual | human review |
| Release | copy CLI/hook + app via `install.sh` | manual | `./scripts/install.sh` |

Index-snapshot pre-commit and stdin-range pre-push are planned. `--no-verify` forbidden on commits and branch pushes.

## Resources / Isolation

| Purpose | Port / resource | Isolation |
|---|---|---|
| Dev/install | `~/.codo/codo.sock`, `~/Applications/Codo.app` | human machine |
| Integration | temp `$HOME/.codo` | `mktemp` in `integration-test.sh` |

## Operations / Release

- Entry: `./scripts/build.sh` then `./scripts/install.sh`. Who: the machine owner (codesign local). No GitHub CD.
- After CLI/hook edits, recopy to `~/.codo`. Live-check: `ps` for Codo/guardian, `ls ~/.codo/codo.sock`, `echo '{"title":"Test","body":"Hello"}' | bun ~/.codo/codo.ts`.

## Retrospective

| Kind | Where |
|---|---|
| Accident narrative | [Retrospective.md](Retrospective.md) |
| Recurring project rule | one line here (cap ~10) |
| Checkable rule | hook or test |

- Installed CLI/hook are copies. Recopy after edits.
- Do not trust `$?` after `echo` in hook scripts (`PIPESTATUS`).

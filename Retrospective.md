# Retrospective

Accident narratives for this repo.

Routing: narrative stays here. A project-specific rule that will recur may become one line in `CLAUDE.md`. Cross-project lessons go to nmem or a global rule. If it can be checked by a machine, add a hook or test instead of prose.

## 2026-03-20: Notification chain silent failure

- **What:** Hooks looked green but no toast. Installed `~/.codo/codo.ts` was v0.1.0 without `--hook`; unknown flags were ignored, then CLI exited 1 on missing title. `claude-hook.sh` captured `echo`'s `$?` (0) instead of the CLI.
- **Why:** Installed CLI/hook are **copies**, not symlinks. New flags never reached `~/.codo` until recopy. `$?` after `echo` hid the failure.
- **Follow-up:** recopy after CLI/hook edits; `hooks.log`; `PIPESTATUS`.

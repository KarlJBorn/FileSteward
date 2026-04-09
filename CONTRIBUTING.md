# Contributing to FileSteward

## Roles

| Role | GitHub account | Responsibility |
|---|---|---|
| Dev lead | KarlJBorn | Product decisions, UI review, PR approval and merge |
| Automation | SpringAgents | Opens PRs, posts review comments on behalf of Claude Code |

## Branch model

- `main` is protected. No direct pushes.
- All work happens on feature branches, merged via PR.
- Branch naming: `iter3/short-description`, `design/topic`, `fix/topic`, `process/topic`.
- Feature branches are **ephemeral** — delete after PR merge.
- Worktrees are **ephemeral** — created per session, deleted when done. One iteration per thread.

## Thread and iteration discipline

- **One iteration per thread.** A thread is scoped to a single iteration. Never open a new thread mid-iteration.
- **Handoffs only at iteration boundaries.** When an iteration is feature-complete, prepare a handoff for the next thread.
- **Ephemeral branches and worktrees.** Feature branches are deleted after merge. Worktrees are created fresh for the session and removed when the iteration ships.

## Development workflow

1. **Design first** — significant changes require a design doc in `docs/` before implementation begins. Open a design PR, get it merged, then implement.
2. **Implement in a branch** — keep changes focused. One concern per PR.
3. **Tests pass** — `make check` (Rust build + Flutter tests) must be green before opening a PR.
4. **Open as draft** — all PRs open as drafts. A draft signals "not yet reviewed."
5. **UI review** — run the app against a real folder and verify the affected screens. This is a required step before a PR is ready to merge.
6. **Convert to ready** — once UI review passes, convert the draft to ready for review.
7. **Approve and merge** — KarlJBorn approves and merges in the browser.

## Why PRs start as drafts

Code passing tests is necessary but not sufficient. FileSteward operates on real user data. UI review catches issues that tests cannot — confusing flows, missing edge case handling, regressions in adjacent screens. No PR should be merged without someone having run the app.

## Design-doc-before-code

For any change that:
- Affects the execution model (how files are modified)
- Changes a user-facing flow (new phase, new screen, new interaction)
- Introduces a new domain concept

...write a design doc in `docs/` first. Capture the decision, the alternatives considered, and the open questions. Get it merged. Then implement.

This practice exists because real-data testing has repeatedly revealed that the "obvious" implementation is wrong in ways that only become clear when you describe the full system behavior in prose.

## Commit messages

- First line: short imperative summary (≤72 chars), prefixed with scope: `Iter 3:`, `Fix:`, `Design:`, `Process:`
- Body: what and why, not how
- Co-authored-by line for Claude Code commits

## Commands

```bash
# Build Rust core
make rust-build

# Run the app (macOS)
make flutter-run

# Run all tests
make check

# Flutter tests only
flutter test

# Rust tests only
cargo test --manifest-path rust_core/Cargo.toml
```

# FileSteward — Iteration 3 Retrospective

## Iteration 3 — Directory Rationalization

**Date completed:** 2026-03-28
**Branch / PR:** `claude/dreamy-chebyshev` / [PR #34](https://github.com/KarlJBorn/FileSteward/pull/34)

---

## What We Built

- **Convention inference engine** (`rust_core/src/convention.rs`) — classifies folder naming conventions (Title Case, snake_case, camelCase, kebab-case, lowercase), detects the dominant convention among siblings, and proposes conservative renames. Token classification preserves dates, versions, and ambiguous ALL_CAPS rather than mis-flagging them.

- **Rationalize pipeline** (`rust_core/src/rationalize.rs`) — full R1–R10 scope:
  - Folder walk with structural metadata (depth, real file count, child names, direct files)
  - Finding generator for all 4 types: `empty_folder`, `naming_inconsistency`, `misplaced_file`, `excessive_nesting`
  - One-level dependency cascade (parent-becomes-empty flagged as a dependent finding with `triggered_by`)
  - Progress streaming, findings JSON output, stdin execution plan parsing, quarantine execution, JSON session log, execution result

- **Flutter model and service layer** — `RationalizeSession` using `StreamIterator` for the two-phase stdin/stdout protocol (scan → execute); full type-safe model layer matching the JSON contract

- **Flutter two-panel UI** (`rationalize_screen.dart`) — findings list with checkboxes, group headers, dismiss, inline destination override with exists/will-be-created indicator; folder tree with badges and bidirectional focus; Preview Changes screen; execution flow; results + re-scan

- **Documentation** — design doc, JSON contract, UI mockup (`mockups/iteration-3-ui.html`), wishlist, retrospective template, corrected iteration plan in CLAUDE.md

- **Test corpus** (`test_corpus/rationalize/`) and integration tests — 116 total (79 Rust, 37 Flutter), all passing

---

## What Worked

- **Upfront JSON contract** — defining the 4-message contract before writing any code let Rust and Flutter develop in parallel with a clear shared interface. No renegotiation mid-build.

- **Conservative flagging as a design principle** — deciding early to skip ambiguous tokens (short ALL_CAPS, brand names) rather than propose bad renames eliminated an entire class of hard edge cases. The "skip rather than risk" rule also made the test cases clean and the output trustworthy.

- **StreamIterator for the two-phase protocol** — the scan → execute stdin/stdout protocol could have been messy. Using `StreamIterator` to step through stdout manually (rather than a stream listener) made both phases linear and easy to reason about.

- **Sealed class hierarchies** — `RationalizeEvent` as a sealed class matched the Rust enum pattern well and made exhaustive switch handling natural in Dart.

- **Test corpus design** — engineering the corpus around the 90% threshold (9 Title Case + 1 snake_case) and explicit cascade scenario meant the integration test assertions were deterministic rather than heuristic.

---

## What Didn't Work

- **`withOpacity` deprecation** — used the old API throughout `rationalize_screen.dart`; had to do a batch replace to `withValues`. Minor, but worth using `withValues` by default going forward.

- **Package name assumption** — used `file_steward` instead of `filesteward` in the first test file import, causing a silent failure (no compile error, just undefined names at test time). Should check `pubspec.yaml` name before writing the first test import.

- **Python fake script indentation** — the injected-binary test helper generated Python with incorrect 4-space indentation (leftover from a class-style template), causing the fake binary to emit nothing. Took two debug passes to find.

- **Context window overflow** — the session split across two context windows. No work was lost (the second session picked up cleanly from the worktree), but the design conversation and the initial code writing happened in different sessions. The "restart flutter track" message mid-work was a token limit hit, not a direction change.

---

## Session Budget Notes

- Hit daily limit: **Y** — the session split mid-Flutter-track (after `rationalize_models.dart` was written)
- What we were doing: writing `rationalize_models.dart`, about to start `rationalize_service.dart`
- Agent use: **none** — all work done inline per preference
- Pattern: long design conversations + code generation in a single session is the highest-cost pattern. Consider starting code-only sessions after design is settled.

---

## Carried Forward

- **iCloud awareness** — evicted stubs (`.icloud` files) and sync-state implications of moves deferred to Iteration 5. The current engine treats all directories as plain local filesystem.
- **Conflict detection at preview time** — the design specifies detecting rename/move conflicts before execution (not mid-execution). Currently execution fails per-action if a conflict is encountered; a proper pre-flight conflict check belongs in a follow-on pass.
- **Misplaced-file coverage** — requires ≥ 4 data points per extension to infer a pattern. Sparse directories won't surface misplaced-file findings. Acceptable for now; could lower threshold or add heuristics later.
- **Quarantine recovery UI** — deferred to Iteration 7. Foundation (quarantine folder + execution log) is in place.
- **Settings** — nesting depth threshold hardcoded at 5. Configurable via settings UI on the wishlist.

---

## Next Iteration

**Iteration 4 — File Cleanup:** within the rationalized directory structure, find and resolve duplicate files using the SHA-256 duplicate groups from the existing manifest engine.

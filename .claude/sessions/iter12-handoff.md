# Iteration 12 — Session Handoff

## Context

FileSteward is a macOS-first Flutter/Dart app with a Rust engine (JSON over stdout IPC).
The current focus is the **Consolidate** flow: multi-folder deduplication → single output directory.

**Branch:** `claude/iter12-fixes-polish`
**Base:** merged from `main` after PR #124 (Iteration 11) merged.

The app is at **v0.6.7**. All tests pass. End-to-end build confirmed working on a
45,416-file real dataset in Iteration 11.

---

## Priority work for this iteration (in order)

### 1. `make run` target — blocking issue (do first)

Structure scan hangs when invoked from the `.app` bundle because macOS TCC blocks the
bundled binary from reading user folders. Workaround confirmed: setting
`FILESTEWARD_RUST_BINARY` to the debug binary bypasses the hang.

Add to `Makefile`:
```makefile
flutter-run:
	pkill -f "FileSteward" || true
	FILESTEWARD_RUST_BINARY=$(PWD)/rust_core/target/debug/rust_core flutter run -d macos
```

This should **kill any existing instance** and launch with the env var pre-set. Without
this, no UI review is possible.

### 2. Screen 4 — black window bug (high priority)

Build progress screen causes the window to go black and become invisible. The app process
stays alive and the build completes (target folder confirmed created), but the result
screen never becomes visible.

Investigate: `ConsolidateBuildConfirmScreen` (`lib/consolidate_build_confirm_screen.dart`).
Build is triggered and NDJSON events stream correctly, but the screen is not re-rendering
on completion.

### 3. Back navigation re-triggers full hash scan (high priority)

`ConsolidateScreen._goBackToScan2()` discards the `_scanResult` held in the orchestrator.
`ConsolidateScan2Screen` always runs `_runScan()` on init.

Fix: Add optional `initialResult` parameter to `ConsolidateScan2Screen`; skip `_runScan()`
when `initialResult` is present.

### 4. Screen 3.2 — dot indicators on wrong side

Dots are currently rendered to the RIGHT of the file icon. They must be on the LEFT —
before the file icon, not after the file name. This is a layout change in
`_TreeNodeRow._buildFile()` in `lib/consolidate_scan2_screen.dart`.

### 5. Screen 3.2 — collapsed state lost on parent toggle

When a parent folder is collapsed and re-expanded, its children lose their individual
expand/collapse state. `ValueKey(child.path)` is already passed but state resets.

Investigate whether `_TreeNodeRow` subtree widgets are being unmounted on parent collapse.
May need to hoist child expanded-state to the parent `_TreeNode` rather than holding it
in widget state.

### 6. Screen 2 — elapsed timer missing (regression)

The structure scan screen has no elapsed timer. Previous iterations had an `MM:SS`
elapsed counter. Add it back to `ConsolidateScan1Screen`
(`lib/consolidate_scan1_screen.dart`).

### 7. Screen 2 — remove pre-hash dots

Coloured dots on file/folder rows are meaningless before content hashing. Remove them
from Screen 2 (structure scan only). They should only appear on Screen 3.2 after
content scan is complete.

### 8. Screen 2 — hide "Shared Structures: 0" metric

The "Shared Structures" metric is always 0 until the folder similarity engine is built
(deferred). Hide it until that engine exists.

### 9. Screen 4 — "Start Build" button removal

The "Start Build" button is wrong. Build begins when the user clicks "Build" on Screen 3.
Screen 4 should show progress immediately on arrival, then the result summary.

Also fix: Screen 4 title reads "Step 3: Review & Build" — should be "Step 4: Build".

---

## Working practices

- Run `make rust-build` before `flutter run` (Flutter invokes Rust at runtime)
- Use `make run` (once added) — kills old instances, sets `FILESTEWARD_RUST_BINARY`
- Run `make check` (Rust build + all tests) before every push — no exceptions
- Bump patch version in `lib/app_version.dart` and `pubspec.yaml` on every UI change
  Karl needs to review (current: `0.6.7`)
- Commit CLAUDE.md after every significant decision (Key Decisions subsection in the
  current iteration section)
- Keep this PR as a draft until Karl confirms the UI is good in a live review

## Key files

| File | Purpose |
|------|---------|
| `lib/main.dart` | App entry; `ConsolidateScreen` orchestrator |
| `lib/consolidate_scan1_screen.dart` | Screen 2 — structure scan + filter |
| `lib/consolidate_scan2_screen.dart` | Screen 3.2 — review trees |
| `lib/consolidate_build_confirm_screen.dart` | Screen 4 — build progress + result |
| `lib/consolidate_service.dart` | Rust IPC — spawns binary, streams NDJSON |
| `lib/consolidate_models.dart` | IPC event/command models |
| `rust_core/src/consolidate.rs` | Consolidate engine |
| `Makefile` | Build commands — `make rust-build`, `make check`, `make flutter-run` |
| `lib/app_version.dart` | `kAppVersion` — keep in sync with `pubspec.yaml` |

## How to start

```bash
make rust-build
# Add make run target first, then:
make run
```

Open draft PR immediately after first commit so CI runs on every push.

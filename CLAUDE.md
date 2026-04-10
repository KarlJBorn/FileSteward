# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this repository.

## How We Work Together

We've learned what makes our sessions go well and what causes them to go off the rails.
These are shared agreements — not bureaucracy, but the habits that keep us aligned and
moving fast without regressions or dropped scope.

- **Version bump on every UI change.** Any change the Product Owner needs to review
  requires a patch bump in both `pubspec.yaml` and `lib/app_version.dart` *before*
  launching. Format: `MAJOR.MINOR.PATCH` — PATCH for fixes/tweaks, MINOR for new
  screens or significant features.

- **Read before writing.** Before implementing any screen or feature, read all relevant
  existing code, prior session docs, and design notes. Never invent UI patterns — check
  what was designed and built in earlier iterations first. Do not regress work from
  Iterations 1–8 without explicit concurrence from the Product Owner.

- **Understand all feedback before writing code.** When the Product Owner gives UI
  feedback, engage with each point — ask clarifying questions, propose solutions, show
  mockups where needed. Do not write code until every feedback item is understood and
  the approach is agreed. Never start fixing item 1 while items 2–5 are still being
  discussed.

- **Lock the design before implementing.** Agree the full design first — mockups,
  discussion, whatever it takes. No partial implementations. No "let's see how this
  looks" commits.

- **Propose, don't build.** Do not add UI elements, controls, or behaviors that weren't
  explicitly designed and agreed. If something seems useful, say so — then wait for the
  go-ahead.

- **Review open PRs at session start.** Before writing any code, run
  `gh pr list --state open`. Close stale PRs with an explanation. Incorporate any
  agreed but unmerged work into the current session scope. Do not open a new PR until
  existing ones are resolved.

- **Open a draft PR at session start.** Before writing any code, open a draft PR and
  list the complete agreed scope in it. Check off each item explicitly before declaring
  done. Never hold scope in context alone — write it down.

- **Confirm the work list before coding.** Enumerate every agreed item, show it to the
  Product Owner, and get explicit confirmation before starting. Do not start until the
  list is confirmed complete.

- **Keep docs current.** When a design is agreed or changed, update `CLAUDE.md` and
  `docs/product-definition.md` in the same session. Never leave documentation describing
  a superseded design. Commit doc changes separately with a clear message (e.g.
  `docs: update Iteration 9 locked design`). Any PR that changes agreed design must
  include the corresponding doc update.

## Commands

```bash
make rust-build          # Build Rust core
make flutter-run         # Run app (macOS)
make check               # Rust build + all tests
flutter test             # Flutter tests only
flutter test test/foo.dart -n "test name"          # Single test
cargo test --manifest-path rust_core/Cargo.toml test_name  # Single Rust test
```

Always build Rust before running Flutter — Flutter invokes the Rust binary at runtime.

## Product Vision

FileSteward takes multiple similarly-structured directories — such as successive backups
— and produces one canonical output by rationalising folder structure, removing
duplicates, and resolving naming conflicts. It is not a bulk-delete tool — every action
is proposed and confirmed before execution. macOS primary; Windows 11, iPadOS, iPhoneOS
targeted.

## Iteration Plan

### Iterations 1–8 ✅ Complete
- **1** CLI engine + manifest (v0.1)
- **2** SHA-256 hashing + duplicate detection + streaming (v0.2)
- **3** Directory rationalisation — side-by-side trees, copy-then-swap (v0.3.5)
- **4** Duplicate file detection — penalty ranker, ambiguous group resolution (v0.4.0)
- **5** Consolidate v1 — primary/secondary model, fold-ins, session persistence (v0.5)
- **6** Consolidate v2 — peer-folder model, per-folder rationalize+fold loop (v0.5.9)
- **7** UX redesign planning — navigation model, wayfinding, review model redesign
- **8** Consolidate UI polish — path truncation, bulk folder preference (v0.6.0)

### Iteration 9 — 2-Scan Consolidate Redesign ✅ Complete (v0.6.5)
**Goal:** Reduce user decisions from thousands to ~20–70.
**Delivered:** Architecture redesign, Screen 1 (Select), Screen 2 (Filter)

**LOCKED DESIGN: 4-Screen Flow**

| Screen | Step | Name | Purpose |
|--------|------|------|---------|
| 1 | Select | Source Selection | Pick 2–4 source folders |
| 2 | Filter | Filter | Browse source trees; exclude file types/folders before hashing |
| 3 | Review | Review | Side-by-side trees; resolve ambiguities before build |
| 4 | Build  | Build  | Progress → completion summary + Open in Finder |

**Two-Scan Architecture:**
- **Scan 1 (no hashing):** `consolidate_structure_scan` — walks sources, counts
  files/types, detects shared folder structures. Powers Screen 2 (Filter).
- **Scan 2 (full SHA-256):** `consolidate_content_scan` — hashes all non-excluded
  files, deduplicates, detects collisions and ambiguities, produces routing plan.
  Powers Screen 3 (Review).

**Screen 2 (Filter) — locked design:** ✅ Implemented
- Left: Finder-style lazy tree per source folder (expandable, right-click to exclude)
- Right: Merged target tree (live view of what will be consolidated)
- File type ribbon: horizontally scrollable with left/right arrows + scrollbar underneath
- "Include again" on extension-excluded file: re-includes that file only via path
  override; does not un-exclude the extension globally
- Exclusions (paths + extensions) passed to Scan 2

**Screen 3 (Review) — locked design (2026-04-09):** ✅ Implemented (v0.6.6)
- Sub-phases 3.1 (hashing) and 3.2 (review) handled within one widget
- 3.1: Deterministic progress bar — "Hashed X of Y files" (total from Scan 1)
- 3.2: Stats band (files to copy, duplicates, output size, issues count)
- 3.2: Left panel — source trees, one collapsible section per source folder (read-only)
- 3.2: Right panel — proposed target tree, color-coded (green=copy, orange=duplicate, ⚠=collision/ambiguity)
- 3.2: Issues panel below trees — one card per collision (both files editable), one card per ambiguity, each with Dismiss button
- 3.2: Build button blocked until all issue cards dismissed
- Collision cards show both the winner and renamed entry as editable name fields

**Screen 4 (Build) — locked design (2026-04-09):** ⏳ Iteration 11
- Progress bar while build executes
- On completion: files copied, duplicates removed, output size, output path
- "Open in Finder" button opens output folder in macOS Finder

**Rust commands (implemented):**
- `consolidate_structure_scan` — Scan 1
- `consolidate_content_scan` — Scan 2
- `consolidate_v3_build` — Build

**Reference docs:** `.claude/sessions/2026-04-08-iter9/architecture-design-v2.md`

### Iteration 10 — Screen 3 Review ✅ Complete (v0.6.6)
**Goal:** Complete Screen 3 (Review) — the hashing progress + post-scan review layout.
**Branch:** great-benz | **Delivered:** v0.6.6

Delivered:
- Deterministic hashing progress bar (totalFiles threaded from Scan 1)
- Side-by-side source/target trees with color-coded status
- Issues panel (collisions with both files editable, ambiguities with Dismiss)
- Build button gated on all issues dismissed
- widget_test updated to reflect Consolidate-only app
- Screen 3 sub-phases named 3.1 (hashing) and 3.2 (review) in code comments

Screen 4 (Build) deferred to Iteration 11 — scope not yet fully agreed.

### Iteration 11 — Screen 4 Build (next)
**Goal:** Build screen with progress bar, completion summary, and Open in Finder.
**See:** Screen 4 locked design above.

### Future Iterations
- **12** iPad/iPhone review client — open saved scans, approve/reject via document picker
- **13** Advanced UX + performance — visual topology, 100k+ file tuning, rules engine

## Architecture

**Stack:** Flutter/Dart (UI), Rust (file engine), JSON over stdout (IPC boundary).
Rust owns all filesystem operations; Flutter is UI only.

**Consolidate data flow:**
1. User selects source folders → `ConsolidateScreen` orchestrates 4-screen flow
2. Scan 1: `ConsolidateService` spawns Rust, sends `consolidate_structure_scan` via stdin
3. Scan 2: sends `consolidate_content_scan` with exclusions from Screen 2
4. Screen 3 receives `ContentScanComplete` (routing, collisions, ambiguities)
5. User resolves all ambiguities → `consolidate_v3_build` executes the routing plan

**Rust binary resolution order:**
1. `FILESTEWARD_RUST_BINARY` env var
2. Sibling of Flutter executable (`Contents/MacOS/rust_core` in .app bundle)
3. `rust_core/target/debug/rust_core` (checked 1–3 directory levels up)

## Key Files

| File | Purpose |
|------|---------|
| `lib/main.dart` | App entry — launches ConsolidateScreen directly |
| `lib/consolidate_screen.dart` | Orchestrates 4-screen Consolidate flow |
| `lib/consolidate_scan1_screen.dart` | Screen 2: Filter (Finder-style trees) |
| `lib/consolidate_scan2_screen.dart` | Screen 3: Review (scan progress + results) |
| `lib/consolidate_build_confirm_screen.dart` | Screen 4: Build + completion summary |
| `lib/consolidate_service.dart` | Spawns Rust binary; streams NDJSON events |
| `lib/consolidate_models.dart` | Consolidate IPC models — events and commands |
| `lib/app_version.dart` | `kAppVersion` — keep in sync with `pubspec.yaml` |
| `lib/rationalize_screen.dart` | Rationalise UI — used within Consolidate flow |
| `lib/rationalize_service.dart` | Rationalise engine integration |
| `rust_core/src/consolidate.rs` | Consolidate engine — scan, diff, build |
| `rust_core/src/rationalize.rs` | Rationalise engine — scan, findings, swap |
| `rust_core/src/convention.rs` | Naming convention classification |
| `test_corpus/` | Fixture folders for Rust and Flutter tests |
| `docs/product-definition.md` | Full product definition + domain model |
| `CONTRIBUTING.md` | Branch model, PR workflow, draft PR convention |

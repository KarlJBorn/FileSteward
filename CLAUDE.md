# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build Rust core
make rust-build
# or: cargo build --manifest-path rust_core/Cargo.toml

# Run the app (macOS)
make flutter-run
# or: flutter run -d macos

# Run all tests (Rust build + Flutter tests)
make check

# Flutter tests only
flutter test

# Single Flutter test file
flutter test test/manifest_service_test.dart

# Single Flutter test by name
flutter test test/manifest_service_test.dart -n "test name here"

# Rust tests only
cargo test --manifest-path rust_core/Cargo.toml

# Single Rust test
cargo test --manifest-path rust_core/Cargo.toml test_name_here
```

Always build Rust before running Flutter (`make rust-build` first) since Flutter invokes the Rust binary at runtime.

## Product Vision

FileSteward will ship as **two separate apps** sharing a common Rust engine. See `docs/product-definition.md` for the full definition.

**FileSteward Maintain** *(current focus)*
Rationalizes a single directory: fixes folder structure, removes duplicate files, enforces naming conventions. Builds a clean copy alongside the source; user confirms a swap when satisfied. Source is never modified until swap is explicitly confirmed.

**FileSteward Consolidate** *(future)*
Takes multiple similarly-structured directories and produces one canonical output. The latest source is the base; non-duplicate content from others is folded in. No swap — the output directory is the result.

**Shared Rust engine** — directory walking, SHA-256 hashing, duplicate detection, build (copy with transformations). Restructure as a library is tracked in #79.

It is **not** a bulk-delete tool; it is an analysis and decision-support tool. Every action is proposed and confirmed before execution.

**Design principles:**
- Safety over cleverness — default to analyze, recommend, confirm; never default to destructive action
- Explainability over magic — every recommendation must show its basis (same hash, naming convention, etc.)
- Engine first, UI second — the Rust core must be fully testable from CLI independent of any UI
- **Rust owns all execution** — all filesystem operations are performed by the Rust engine; Flutter is UI only
- Desktop first — macOS primary, Windows 11 secondary; iPad/iPhone for review only

**Target platforms:** macOS (primary), Windows 11, iPadOS, iPhoneOS. No Android target.

## Domain Model

| Entity | Description |
|--------|-------------|
| `ScanSession` | One run of the scanner against a folder |
| `Asset` | A file discovered during a scan |
| `Fingerprint` | A SHA-256 content hash identifying file content |
| `Finding` | A structural problem or duplicate group found during scan |
| `DuplicateGroup` | Set of assets with identical fingerprints |
| `ProposedAction` | Keep / rename / move / remove recommendation |
| `ApprovalDecision` | Human confirmation of a proposed action |
| `BuildResult` | Outcome of building the rationalized copy |
| `SwapResult` | Outcome of the source ↔ copy swap |
| `ExecutionLog` | Record of what was actually done and when |

## Iteration Plan

### Iteration 1 — CLI Engine + Manifest ✅ Complete
- Rust recursive directory walker with metadata
- JSON manifest output (relative path, type, size)
- Flutter UI: folder selection, manifest display, filtering
- GitHub Actions CI pipeline
- Test corpus and Flutter unit tests

### Iteration 2 — Hashing, Duplicate Detection, Streaming ✅ Complete
- SHA-256 file hashing in Rust (scoped by extension)
- Exact duplicate detection: group files by hash
- Duplicate groups exposed in JSON output
- Streaming progress from Rust to Flutter UI
- Flutter model and UI updates to show duplicate groups

### Iteration 3 — Directory Rationalization ✅ Complete (v0.3.5)
- Rationalize screen: side-by-side Original / Target directory trees
- Findings engine: empty folders, naming inconsistencies, excessive nesting
- Copy-then-swap safe execution model (source never modified until swap confirmed)
- Naming engine: reserved words blocked, all-caps identifiers never renamed, date preservation
- Right-click context menu: accept/reject findings, mark any folder for removal, bulk dismiss subtree
- Build progress + results screen with stats (folders copied, files copied, omitted)
- Splash screen with version number
- Draft PR convention + CONTRIBUTING.md

### Iteration 4 — Duplicate File Detection ✅ Complete (v0.4.0)
- SHA-256 hashing wired into the rationalize scan
- Penalty-based duplicate ranker: auto-resolves clear cases, flags ambiguous groups for user decision
- Duplicate resolution panel below the tree: auto-resolved summary + keeper selection for ambiguous groups
- Apply blocked until all ambiguous groups resolved
- Build step omits non-kept duplicate copies via `duplicate_removals`
- Collapsible/expandable folder nodes in both tree panels (depth ≥ 2 starts collapsed)
- `docs/product-definition.md` updated to reflect Maintain-first approach and two-app vision

### Iteration 5 — Consolidate v1 (current, in progress — PR #104)
**Goal:** First working Consolidate flow. Primary/secondary model as a stepping stone.

Done:
- Multi-folder selection UI: one "primary" + up to two "secondaries"
- Engine: Rayon parallel hashing, size pre-filter, system file filtering
- Cross-folder diff: unique files per secondary (content not present in primary)
- User reviews unique files per source; toggles Keep/Skip
- Engine builds output directory (fold-ins only; no swap)
- Scan resume: results persisted to `~/.filesteward/sessions.json`; resume card on re-open
- Progress: linear bar, per-source status rows, elapsed MM:SS timer for scan + build
- Overwrite warning dialog before build
- Target directory: user-configurable location + name (auto-populated from primary)
- Dangerous path guard (rejects volume roots and system directories)
- Version shown in AppBar; splash screen removed
- Rust binary bundled inside .app via Xcode Run Script build phase
- Rust binary resolved from bundle-sibling path (`Contents/MacOS/rust_core`)

### Iteration 6 — Consolidate v2: Per-Folder Orchestrated Rationalize + Fold ✅ Complete (v0.5.9)

Done:
- Peer-folder model replacing primary/secondary (Folder 1/2/3)
- `consolidate_rationalize_scan` — walks one folder, detects internal duplicate groups,
  ranks with penalty scorer, flags ambiguous cases
- `consolidate_fold_scan` — diffs one folder against session's accumulated hash set
- `consolidate_accumulate` — persists approved hashes to session registry after each review
- `consolidate_v2_build` — copies all approved files from all folders into target
- `penalty_score` in rationalize.rs made pub for reuse in consolidate.rs
- SessionRecord gains `accumulated_hashes` + `folders` fields (backward-compatible)
- Dart models, service methods, and screen redesigned for per-folder phase loop
- Rust test: duplicate detection verified with temp fixture

**Note:** Review UX revealed as insufficient during testing (2026-04-03):
- Fold review shows all files from Folder 1 (4484 files) because target starts empty — not useful
- File-by-file review is unworkable at scale
- Directory-level duplicate grouping needed (two folders with same content should offer a
  folder-level keep/discard decision, not individual file decisions)
- These issues drive the Iteration 7 redesign

### Iteration 7 — Pure Consolidate App: 7-Step UX Redesign ✅ Complete (v0.6.1)

**Delivered:**
- FileSteward Consolidate is a standalone app — Maintain/Rationalize stripped (#110)
- 7-step stepper: Select → Filter → Scope → Scan → Review → Build → Done (#111)
- Folder and File Filter: extension checkboxes, pre-selected important types (#112)
- Scope Review: summary card before scan (#113)
- Review: summary chips + duplicate group cards, ambiguous groups expanded (#114)
- Rust consolidate_unified_scan: hashes all folders in one pass, groups by
  content hash, absolute paths, penalty-score ranking (#115)
- Important-extensions constant (_kImportantExtensions): photos, video, audio,
  documents pre-selected by default; falls back to all if none present

**Deferred to Iteration 8:**
- #116 help scaffold (? button per step — purely additive, scope closed cleanly)
- #87 ranker refinement
- #38 multi-folder picker
- #101 test corpus
- Two-panel tree view (Step 2 + Step 5) — designed, documented above

**Reusable pieces for Iteration 8:**
- Rust: hash_file, walk_files, should_skip_dir/file, collect_hashes, penalty_score,
  v2_build, accumulate, consolidate_unified_scan
- Dart: _TreeNode/_TreeNodeRow/_OriginalTreePanel → two-panel tree view
- Dart: _StepDot, _SectionHeader, _SourceTile, _BottomBar, _ErrorBanner,
  _ScopeChip, _SummaryChip → carry forward unchanged

### Iteration 8 — Two-Panel Tree View (agreed 2026-04-03)

**Cut line from Iteration 7:** The two-panel layout materially changes the
build step (Dart must translate folder-level include/exclude decisions into
the build command), so it is cleanly deferred here.

**Step 2 (Folder and File Filter) — pre-scan, two-panel:**
- Left panel: N source folder trees, color-coded (colors from Step 1),
  lazy expansion (walk one level on tap, like Finder — never load full tree
  upfront)
- Right panel: naive merged target — ordered combination of all source
  folders, duplicate paths flagged, ambiguities indicated; also lazy
- Extension checkbox screen is REMOVED; filtering moves into the tree via
  right-click context menu (see below)
- No hashing at this step — directory walk only

**Step 5 (Review) — post-scan, two-panel:**
- Left panel: source trees, color-coded, annotated (duplicate markers,
  provenance dots, which copy was kept)
- Right panel: final view of expected consolidated, deduped target tree —
  interactive at folder level (include/exclude per folder), read-only at
  file level in this iteration
- OS folder name mapping applied silently (macOS table: My Pictures →
  Pictures, My Documents → Documents, My Videos → Movies, My Music →
  Music); mapping shown as unobtrusive annotation; mechanism for
  questioning/overriding a mapping is TBD (UI only, Rust unchanged)
- Folder-level decisions drive exactly what the Build step executes

**Folder exclusion:**
- Checkbox next to each folder node in the right panel; checked = included,
  unchecked = excluded — no toggles, no color-only states
- Excluding a folder is absolute: nothing from it reaches the target
- Step 2 exclusions affect the target only; the scan (Step 4) still hashes
  everything — exclusions are applied when building, not when scanning
- Step 5 right panel uses the same checkbox model

**Duplicate path indicator (Step 2 right panel):**
- Each file appears exactly once in the merged target tree
- A small colored dot per source that contributed that file sits beside it
- One dot = unique to one source; two or more dots = duplicate, will need
  resolution in Step 5
- Dot colors match the source folder colors from Step 1

**Right-click context menu (both panels):**
- "Exclude this file" — removes one file from target
- "Exclude all [.ext] files" — removes that file type from target scope
- Right-clicking a folder node: "Exclude this folder" — unchecks it
- Language is always "Exclude", never "Delete" (safety-first principle)
- Long-press equivalent for future iPad/iPhone

**Reusable pieces:**
- _TreeNode/_TreeNodeRow/_OriginalTreePanel from rationalize_screen.dart
- v2_build Rust command unchanged; Dart side adds folder-level decision
  tracking

**Parked / TBD:**
- Visual treatment for "questionable" OS name mapping override link
- File-level override interactions (later pass)
- Settings table for user-customisable important-extensions list

### Iteration 9 — iPad/iPhone Review Client
- Open saved scan, review groups, approve/reject recommendations
- Focused scans via Apple document picker / security-scoped URLs
- Sync saved scan state

### Iteration 10 — Advanced UX + Performance
- Visual topology of folders and duplicate clusters
- Performance tuning for large external drives (100k+ files)
- Rules engine: user-defined naming and placement rules

## Architecture

**Stack:** Flutter/Dart (UI), Rust (file engine), JSON over stdout (integration boundary).

**Rationalize data flow:**
1. User picks a folder; `RationalizeScreen` passes it to `RationalizeService`
2. `RationalizeService` spawns the Rust binary as a subprocess, sends a `scan` command via stdin
3. Rust walks the directory, generates findings, streams progress events and a `findings` payload to stdout
4. Flutter parses events into `FindingsPayload` (`lib/rationalize_models.dart`)
5. User reviews side-by-side Original/Target trees, accepts/rejects/marks findings
6. On apply: `RationalizeService` sends a `build` command; Rust builds rationalized copy, streams progress
7. On swap confirm: `RationalizeService` sends a `swap` command; Rust renames source → `.OLD`, copy → source

**Rust binary resolution order:**
1. `FILESTEWARD_RUST_BINARY` env var
2. Sibling of the Flutter executable (`Contents/MacOS/rust_core` in .app bundle)
3. `rust_core/target/debug/rust_core` (checked at 1–3 directory levels up)

The Xcode project includes a "Copy Rust Binary" Run Script build phase that copies the debug
(or release if available) Rust binary into `Contents/MacOS/` on every `flutter build macos`.

## Working Patterns

**Design before branch.** No branch is opened and no code is written until the flow for
that iteration is fully agreed and documented in CLAUDE.md. The sequence is:
1. Use case and scenarios — understand the real problem
2. Step sequence — agree the user-facing flow end to end
3. Terminology — lock down names before they get baked into code
4. Edge cases — work through the hard cases in conversation, not in code
5. Document in CLAUDE.md — the agreed design is the source of truth
6. Open issues — one per logical unit of work
7. Open draft PR — then write code

Skipping steps 1–5 and going straight to code is hacking. Both parties are responsible
for enforcing this. If implementation starts before the design is clear, stop and design.

**Bump patch version** on every UI change Karl needs to review
(e.g. 0.5.8 → 0.5.9). Update `lib/app_version.dart` and `pubspec.yaml`.

**Merge main before starting.** Always pull main onto the feature branch before
beginning new work.

**No subagents for design decisions.** Subagents can implement agreed designs but must
not make product or UX decisions autonomously.

## Key Files

| File | Purpose |
|------|---------|
| `lib/main.dart` | App entry, home screen, folder selection, manifest display |
| `lib/rationalize_screen.dart` | Full rationalize UI — scan, review, build, swap |
| `lib/rationalize_service.dart` | Spawns Rust binary, manages scan/build/swap session |
| `lib/rationalize_models.dart` | `FindingsPayload`, `RationalizeFinding`, `BuildResult`, `SwapResult` |
| `lib/rationalize_events.dart` | Typed event stream from Rust (progress, findings, errors) |
| `lib/manifest_service.dart` | Legacy manifest scan — spawns Rust binary, parses stdout JSON |
| `lib/manifest_models.dart` | `ManifestEntry`, `ManifestResult` |
| `lib/app_version.dart` | `kAppVersion` constant — keep in sync with `pubspec.yaml` |
| `lib/consolidate_screen.dart` | Consolidate UI — source selection, scan, review, build, result |
| `lib/consolidate_service.dart` | Spawns Rust binary in `consolidate` mode; streams NDJSON events |
| `lib/consolidate_models.dart` | Consolidate IPC models — events and commands |
| `rust_core/src/consolidate.rs` | Consolidate engine — scan, diff, build, session registry |
| `rust_core/src/rationalize.rs` | Rationalize engine — scan, findings, build, swap |
| `rust_core/src/convention.rs` | Naming convention classification and rename suggestions |
| `rust_core/src/main.rs` | Manifest scan path — walker, hashing, duplicate groups |
| `test_corpus/` | Fixture folders used in Rust and Flutter tests |
| `docs/product-definition.md` | Two-app product definition (Maintain + Consolidate) |
| `CONTRIBUTING.md` | Branch model, PR workflow, draft PR convention |

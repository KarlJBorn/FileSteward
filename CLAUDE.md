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

### Iteration 7 — UX Redesign: Navigation, Wayfinding, and Consolidate Workflow

**Design agreed 2026-04-03:**

**Core terminology clarification:**
- "Rationalize" = scope selection (browse folder tree, exclude junk dirs/file types, no hashing)
- "Consolidate" = the full workflow: rationalize all folders → scan → review → build

**App architecture (agreed 2026-04-03):**
FileSteward Consolidate is a standalone app. The Maintain/Rationalize screen has been
stripped out entirely. "Rationalize" is NOT a term used inside Consolidate — it belongs
to the Maintain app. The scope-definition step inside Consolidate is called
"Folder and File Filter." Maintain will be a separate app sharing the Rust engine.

**Agreed 7-step Consolidate workflow:**

1. **Select** — add N source folders, set target directory, confirm
2. **Folder and File Filter** — one source folder at a time: quick inventory scan (no
   hashing), show folder tree with checkboxes, system/junk dirs auto-excluded by default,
   file type filter shows only unusual types not in the default known-types list.
   User removes directories and file types they don't want consolidated.
3. **Scope Review** — per-folder file counts + total size; chance to go back and adjust
   any folder's filter before committing to the hash scan
4. **Scan** — hash all in-scope files across all folders simultaneously (progress + timer)
5. **Review** — summary card first:
   - "X files will be copied to target"
   - "Y duplicate groups auto-resolved by ranker"
   - "Z ambiguous groups need your input" (only action required)
   - "W unique files from folders with no overlap"
   Only ambiguous groups require user decisions. Auto-resolved and unique files visible
   but collapsed — user can expand to inspect or override.
   Pattern recognition: after user resolves ambiguous cases, app detects if a rule
   applies to remaining groups and shows proposed decisions for bulk confirmation.
6. **Build** — copy approved files to target preserving source structure (progress + timer)
7. **Done** — stats, open target folder button

**Navigation model:**
- Stepper pattern: always-visible step indicator showing current step and progress
- Back navigation available at every step except after Build
- No phase labels in content headers — wayfinding comes from the stepper only
- System/junk dirs auto-excluded everywhere by default

**Folder matching across sources:**
Folders are matched (treated as the same logical folder) at two levels:
1. Exact name match — `My Pictures` in source A and `My Pictures` in source B
2. OS-equivalent name match — Windows and macOS use different canonical names for
   the same standard folders:
   | Windows       | macOS/cross-platform |
   |---------------|----------------------|
   | My Pictures   | Pictures             |
   | My Documents  | Documents            |
   | My Videos     | Movies               |
   | My Music      | Music                |
   | Desktop       | Desktop              |
   The target always uses the current OS's canonical name (macOS for now).
   The mapping is platform-aware and must flex for Windows targets in future.
3. Content overlap match (future iteration) — differently named folders with high
   duplicate content rate

**Winner selection (when the same logical folder exists in multiple sources):**
- App suggests the most complete / most recent source version; user can override
- Terminology: source folders → winner (suggested) → target
- Non-winner folders contribute only their unique files into the winner's structure

**Duplicate resolution rules (when same content exists in multiple paths):**
- If user excluded one path's folder during Rationalize, the included path wins automatically
- If both paths included: most recent modification time wins
- If timestamps equal: penalty ranker score wins (shallower path, better folder name, etc.)
- If scores equal: ambiguous — surface to user

**Auto-excluded file types (cross-platform junk):**
Windows: .lnk, Thumbs.db, desktop.ini, .url, .tmp
macOS: .DS_Store, .AppleDouble, __MACOSX/
Both: system/temp folder contents (already in should_skip_dir)

**Session continuation (future):**
After a completed build, user can add another folder and pick up where they left off.
The session knows what hashes are already in the target; new folder goes through
Rationalize → Scan (incremental) → Review → Build without re-scanning existing content.

**App-wide UX principles (apply across both Rationalize and Consolidate):**
- Always show which step you're on and how many remain
- Back navigation available at every step except after Build
- System/junk folders auto-excluded by default everywhere
- Progress bars + elapsed timers for all long-running operations
- Destructive actions require explicit confirmation

**Reusable pieces:**
- Rust: hash_file, walk_files, should_skip_dir/file, collect_hashes, penalty_score,
  v2_build, accumulate — all carry forward unchanged
- Dart: _TreeNode/_TreeNodeRow/_OriginalTreePanel (rationalize_screen) → adapt for
  Rationalize step folder tree with checkboxes
- Dart: _DuplicateGroupsPanel/_DuplicateGroupCard (rationalize_screen) → ambiguous groups
- Dart: _ReviewRow/_ReviewBottomBar, _BottomBar, _ErrorBanner, _buildBuilding,
  _buildResult (consolidate_screen) → carry forward

### Iteration 8 — iPad/iPhone Review Client
- Open saved scan, review groups, approve/reject recommendations
- Focused scans via Apple document picker / security-scoped URLs
- Sync saved scan state

### Iteration 9 — Advanced UX + Performance
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

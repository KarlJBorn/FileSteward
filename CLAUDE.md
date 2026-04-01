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

## Working Patterns

**Merge before starting new work.** Always pull main before branching for a new task. If Karl hasn't merged the outstanding PR before asking for the next one, remind him — don't proceed without it.

**PR workflow.** PRs are opened by the `SpringAgents` gh CLI account (set via `gh auth switch --user SpringAgents` — the SessionStart hook handles this automatically). Karl approves and merges in the browser. Never push directly to main.

**Do it proactively.** Update docs, CLAUDE.md, and open PRs as part of completing a task — don't wait to be asked.

**No subagents.** Do all work inline. Don't spawn subagents unless Karl explicitly asks or the task genuinely requires parallelism. Subagents consume quota faster and Karl prefers direct work while the project is in early iterations.

**Never invent commands.** Don't fabricate slash commands or CLI flags. If unsure whether something exists, check first.

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

### Iteration 5 — Consolidate App (first version)
**Goal:** FileSteward Consolidate v1. Multiple source directories → one canonical output.

- Multi-folder selection (#38)
- Engine: walk all sources, fingerprint files, identify unique content not in primary
- User reviews: which unique files to fold in
- Engine builds output directory (no swap)
- Cleaning rules applied to secondary sources before folding (skip empty, reserved, system folders)
- Rust core restructured as shared library (#79)

### Iteration 6 — iPad/iPhone Review Client
- Open saved scan, review groups, approve/reject recommendations
- Focused scans via Apple document picker / security-scoped URLs
- Sync saved scan state

### Iteration 7 — Advanced UX + Performance
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
2. `rust_core/target/debug/rust_core` (checked at 1–3 directory levels up)

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
| `lib/splash_screen.dart` | Launch splash showing version number |
| `rust_core/src/rationalize.rs` | Rationalize engine — scan, findings, build, swap |
| `rust_core/src/convention.rs` | Naming convention classification and rename suggestions |
| `rust_core/src/main.rs` | Manifest scan path — walker, hashing, duplicate groups |
| `test_corpus/` | Fixture folders used in Rust and Flutter tests |
| `docs/product-definition.md` | Two-app product definition (Maintain + Consolidate) |
| `CONTRIBUTING.md` | Branch model, PR workflow, draft PR convention |

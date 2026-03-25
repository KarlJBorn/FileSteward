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

FileSteward rationalizes consolidated backup disks — finding duplicates, classifying files, recommending safe actions, and providing a full audit trail. It is **not** a bulk-delete tool; it is an analysis and decision-support tool.

**Design principles:**
- Safety over cleverness — default to analyze, recommend, quarantine, confirm; never default to destructive action
- Explainability over magic — every recommendation must show its basis (same hash, newer timestamp, user rule, etc.)
- Engine first, UI second — the Rust core must be fully testable from CLI independent of any UI
- Desktop first, mobile second — macOS/Windows for full-drive rationalization; iPad/iPhone for review and targeted scans

**Target platforms:** macOS (primary), Windows 11, iPadOS, iPhoneOS. No Android target.

## Domain Model

The core entities the app reasons about:

| Entity | Description |
|--------|-------------|
| `Volume` | A physical or logical drive being rationalized |
| `ScanSession` | One run of the scanner against a folder or volume |
| `Asset` | A file discovered during a scan |
| `Fingerprint` | A content hash (SHA-256) identifying file content |
| `DuplicateGroup` | Set of assets with identical fingerprints |
| `SimilarityGroup` | Set of assets that are likely duplicates (near-match) |
| `ProposedAction` | Keep / archive / quarantine / delete recommendation |
| `ApprovalDecision` | Human confirmation of a proposed action |
| `ExecutionLog` | Record of what was actually done and when |
| `Exception` | User-defined exclusion or override rule |

## Iteration Plan

### Iteration 1 — CLI Engine + Manifest (current)
**Status:** Mostly complete. Hashing not yet implemented.

Done:
- Rust recursive directory walker with metadata
- JSON manifest output (relative path, type, size)
- Flutter UI: folder selection, manifest display, filtering
- GitHub Actions CI pipeline
- Test corpus and Flutter unit tests

**Remaining to complete Iteration 1:**
- SHA-256 file hashing in Rust (add to `ManifestEntry`)
- Exact duplicate detection: group files by hash
- Expose duplicate groups in the JSON output
- Flutter model and UI updates to show duplicate groups
- Tests: fixture-based duplicate detection tests in Rust; Flutter tests for duplicate group parsing

### Iteration 2 — Desktop UI: Scan, Review, Export
- Full desktop Flutter UI for macOS (and Windows)
- Safe simulation mode (propose actions, no execution)
- Quarantine workflow (move to staging, not delete)
- Export scan report (CSV or JSON)

### Iteration 3 — Rules Engine + Similarity + Undo
- Similarity detection (name-based, image-based)
- User-defined rules (prefer newer, prefer higher resolution, folder priority)
- Undo / revert operations
- Full audit log

### Iteration 4 — iPad/iPhone Review Client
- Narrower scope: open saved scan, review groups, approve/reject recommendations
- Focused scans via Apple document picker / security-scoped URLs
- Sync saved scan state

### Iteration 5 — Advanced UX + Performance
- Visual topology of folders and duplicate clusters
- Recommendation engine
- Performance tuning for large external drives (100k+ files)

## Architecture

**Stack:** Flutter/Dart (UI), Rust (file engine), JSON over stdout (integration boundary).

**Data flow:**
1. User picks a folder in Flutter UI
2. `ManifestService` (`lib/manifest_service.dart`) spawns the Rust binary as a subprocess
3. Rust walks the directory, computes hashes (Iteration 1+), outputs JSON to stdout
4. Flutter parses JSON into models (`lib/manifest_models.dart`)
5. `ManifestFilter` (`lib/manifest_filter.dart`) applies type/search filters
6. Results render in `main.dart`

**Rust binary resolution order:**
1. `FILESTEWARD_RUST_BINARY` env var
2. `rust_core/target/debug/rust_core` (checked at 1–3 directory levels up)

**Current Rust output shape** (`ManifestResult`):
```json
{
  "selected_folder": "/path/to/folder",
  "exists": true,
  "is_directory": true,
  "total_directories": 4,
  "total_files": 12,
  "entries": [
    { "relative_path": "foo/bar.jpg", "entry_type": "file", "size_bytes": 204800 }
  ]
}
```
When hashing is added, `ManifestEntry` gains `sha256: Option<String>` and the output gains `duplicate_groups: Vec<Vec<String>>`.

## Key Files

| File | Purpose |
|------|---------|
| `lib/main.dart` | App entry, UI state, folder selection, manifest display |
| `lib/manifest_service.dart` | Spawns Rust binary, parses stdout JSON |
| `lib/manifest_models.dart` | `ManifestEntry`, `ManifestResult` with JSON deserialization |
| `lib/manifest_filter.dart` | Filter by type (all/dirs/files) and search query |
| `rust_core/src/main.rs` | Recursive directory walker, JSON serializer |
| `test_corpus/` | Fixture folders used in tests |

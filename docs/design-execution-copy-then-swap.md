# FileSteward: Copy-Then-Swap Execution Model

## Status
Approved. Supersedes the in-place execution model described in
[`design-iteration-3.md`](design-iteration-3.md) (execution section) and
[`json-contract-iteration-3.md`](json-contract-iteration-3.md) (execute phase).

**Decision date:** 2026-03-31
**Origin:** Real-data testing against `Born_Family_2000_01_24` (live data) revealed
that the current engine modifies the source directory in place, which is unsafe for
production data.

---

## The Problem With In-Place Execution

The current engine applies rename, move, and quarantine operations directly to the
source directory. This means:

- A failed mid-run leaves the source in a partially-modified state
- There is no safe rollback — quarantine only covers removed items, not renames or moves
- The user cannot verify the rationalized result before committing
- Running against live data (not a test corpus) carries real risk of data loss

`Born_Family_2000_01_24` is live data. In-place execution is not acceptable for live data.

---

## The Decision: Copy-Then-Swap

The engine never touches the source directory. Instead:

1. **Scan** — walk the source, generate findings (unchanged)
2. **Review** — user reviews before/after tree, rejects findings as needed (unchanged)
3. **Build** — engine builds a rationalized copy of the source alongside it
4. **Verify** — user reviews the built copy on disk before committing
5. **Swap** — user explicitly triggers the swap: source renamed to `<name>.OLD`,
   copy renamed to `<name>`

The source is untouched until step 5, and step 5 is always an explicit user action.

---

## Build Phase (replaces Execute)

### What "Build" means

The engine creates a new directory tree from scratch, populated by copying content
from the source and applying the approved rationalization decisions:

| Finding action | Build behavior |
|---|---|
| `rename` | Folder created at new name; contents copied from source |
| `move` | Folder created at new location; contents copied from source |
| `remove` | Folder omitted from copy entirely |
| No finding (clean) | Folder and contents copied as-is |

Files within each folder are copied verbatim. File-level rationalization
(deduplication, renaming, classification) is a future iteration — for now all files
in a kept folder are copied.

### Target directory location

Default: same parent as source, with suffix `_rationalized`.

Example:
```
/Volumes/Backup/Born_Family_2000_01_24            ← source, never touched
/Volumes/Backup/Born_Family_2000_01_24_rationalized  ← built copy
```

The target path is shown to the user before the build begins. The user can change it.

### Incremental builds

If the target directory already exists (partial prior build), the engine reports
the conflict and requires the user to either delete the existing target or choose
a new location. No silent overwrites.

### Progress

The build phase replaces the current "Executing…" spinner with a real progress
indicator: folders copied / total folders, current file being copied.

---

## Swap Phase

The swap is a separate, explicit step shown after the build completes. The UI presents:

- Path of the source (`Born_Family_2000_01_24`)
- Path of the `.OLD` backup it will become (`Born_Family_2000_01_24.OLD`)
- Path of the rationalized copy that will take its place

The user must confirm before the swap executes. The swap itself is two renames:

```
Born_Family_2000_01_24          → Born_Family_2000_01_24.OLD
Born_Family_2000_01_24_rationalized → Born_Family_2000_01_24
```

If either rename fails (e.g., disk full, permissions), the operation stops and
reports the error. The source is never left in an ambiguous state: if the first
rename fails, nothing happens; if the second rename fails (rare), the user still
has the `.OLD` and the rationalized copy under its temp name.

---

## What Happens to Quarantine

Under the in-place model, "remove" meant move-to-quarantine. Under copy-then-swap,
"remove" means omit from the copy. The `.OLD` directory after swap is the recovery
path for any removed item — the user can retrieve anything from `.OLD` that was
omitted from the rationalized copy.

Quarantine (`~/.filesteward/quarantine/`) is retired as an execution mechanism.
It may be repurposed later as a staging area for file-level deduplication.

---

## Impact on Current Implementation

### Rust engine (`rationalize.rs`)

| Current function | Disposition |
|---|---|
| `execute_remove()` | Remove — replaced by omit-from-copy logic |
| `execute_rename_or_move()` | Remove — replaced by copy-to-new-location logic |
| `move_with_cross_device_fallback()` | Reusable — copy-then-delete is now the primary path, not a fallback |
| `copy_dir_all()` | Reusable — becomes the core build primitive |
| `find_available_suffixed()` | Remove — collision is impossible in a fresh target directory |

New entry point: `build_target(source, target, approved_plan)` that walks the
source and constructs the target.

### Flutter (`rationalize_screen.dart`)

- `_Phase.executing` → renamed `_Phase.building`
- Results screen updated to reflect build completion, not action counts
- Swap confirmation added as a new screen/dialog after build
- `_kCollisionSuffixColor` no longer needed in findings phase (collisions cannot
  occur in a fresh target); may be repurposed for file-level work

### JSON contract

New event type emitted during build phase:

```json
{ "event": "build_progress", "folders_done": 12, "folders_total": 47, "current": "Photos/2000" }
```

Build completion:

```json
{ "event": "build_complete", "target_path": "/Volumes/Backup/Born_Family_2000_01_24_rationalized", "folders_copied": 47, "files_copied": 1203, "folders_omitted": 8 }
```

Swap completion:

```json
{ "event": "swap_complete", "old_path": "/Volumes/Backup/Born_Family_2000_01_24.OLD", "new_path": "/Volumes/Backup/Born_Family_2000_01_24" }
```

---

## Open Questions

| # | Question | Status |
|---|---|---|
| 1 | Should the target location be configurable before build, or always alongside source? | Default alongside source; user can change — **approved** |
| 2 | Should the swap step be in this app or left to the user (Finder rename)? | In-app — **approved** |
| 3 | Should the `.OLD` backup be auto-deleted after a grace period? | No — user-controlled — **approved** |
| 4 | What is the file copy strategy for very large directories (progress, cancellation)? | Future iteration |
| 5 | Should build be resumable if interrupted? | Future iteration |

---

## Implementation Sequence

1. Update `design-iteration-3.md` and `json-contract-iteration-3.md` to reference this doc
2. Rust: implement `build_target()` using `copy_dir_all()` as primitive
3. Rust: remove `execute_remove()`, `execute_rename_or_move()`
4. Flutter: replace Execute phase with Build phase (progress UI)
5. Flutter: add Swap confirmation screen
6. Tests: fixture-based build tests in Rust; Flutter tests for build/swap flow

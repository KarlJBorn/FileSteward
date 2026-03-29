# FileSteward: Iteration 3 Design — Directory Rationalization

## Status
Approved.

**UI mockup:** [`mockups/iteration-3-ui.html`](../mockups/iteration-3-ui.html)

---

## Goal

Analyze and reorganize the folder structure of a directory. Folder-level operations only — no file content analysis.

---

## Architectural Principle

**Rust owns all execution.** All filesystem operations — rename, move, quarantine, execution log — are performed by the Rust engine. Flutter collects user decisions and overrides, packages them as an execution plan, and passes them to Rust as a command. Flutter never touches the filesystem directly.

This keeps all destructive operations testable from CLI, independent of any UI.

---

## Scope Decisions

### Folder selection
The user picks any folder via the existing folder picker. No hardcoded paths. `~/Documents` is a natural default but not required. iCloud-backed directories are supported transparently — the folder is treated as a plain local directory regardless of iCloud backing.

### iCloud awareness — deferred
iCloud-specific behavior is explicitly out of scope for this iteration:
- Evicted stub files (`.icloud`) — deferred
- Sync state implications of moving files into/out of synced directories — deferred

Target iteration for iCloud awareness: Iteration 5 (Consolidate) or a follow-on.

---

## Finding Types

Analysis identifies the following structural problems:

| Type | Severity | Description |
|------|----------|-------------|
| Empty folder | Issue | Folder contains no files or subfolders |
| Naming inconsistency | Issue | Folder name deviates from the inferred convention |
| Misplaced file | Warning | File type doesn't match the folder's inferred purpose |
| Excessive nesting | Warning | Folder depth exceeds threshold (default: 5 levels, hardcoded) |

### Convention inference
Naming conventions and file placement rules are **inferred from the existing structure**, not configured by the user. Examples:
- If 90%+ of sibling folders use Title Case, outliers are flagged
- If `.jpg` files only appear in `Photos/` subtrees, any outside that subtree are flagged

Inference confidence is shown to the user via a **(why?)** affordance on each finding. Explicit user-defined rules are deferred to a later iteration.

#### Token classification for rename conversion
When renaming a folder to match the inferred convention, the name is split into typed tokens:

| Token type | Examples | Rename treatment |
|------------|----------|-----------------|
| Word | `photos`, `backup` | Apply target convention |
| Acronym | `HP`, `KPMG`, `IBM` | Preserve as-is (whitelist-driven) |
| Date appendix | `2000_01_24`, `1999-12` | Preserve whole segment as-is |
| Date part | `2000`, `01` | Preserve as-is |
| Version | `v3`, `v2` | Preserve as-is |

**Conservative flagging:** Folder names containing tokens that cannot be confidently classified are not flagged. Only clear-cut cases are surfaced (e.g. `photoArchive`, `old_receipts`). Ambiguous cases (e.g. `OLD_files`, `KODAK_backup`) are skipped rather than risk a bad rename proposal.

**AI increment:** Semantic token classification (distinguishing acronyms from stylistic ALL CAPS, identifying brand names, etc.) is deferred to a future AI-powered increment. Rule-based inference handles the unambiguous majority.

### Near-empty folders
A folder is considered **empty** if it contains no files other than macOS system metadata files. These are treated as non-content and excluded from all file counts:

- `.DS_Store` — Finder view settings (icon positions, sort order, window size)
- `.localized` — macOS localization metadata
- `Thumbs.db` — Windows thumbnail cache (may appear on cross-platform volumes)

**Folders with a single real file** are not flagged — deferred to the product wish list.

---

## UI Design

### Layout
Two-panel view:
- **Left — Findings list**: findings grouped by type, with checkboxes for selection and proposed actions
- **Right — Folder tree**: Finder-style list view (Name / Date Modified / Size / Findings columns) annotated with color-coded badges; selecting a finding highlights the relevant tree nodes, and vice versa (bidirectional)

### Finding row
Each finding shows:
- Type badge (color-coded)
- Folder/file name and relative path
- Proposed action with destination (for moves)
- **Choose location…** override for any action involving a move

### Destination override
When the user chooses an alternate location:
- Inline path input with Browse button (native macOS folder picker, which includes New Folder)
- Real-time indicator below the input: **● Folder exists** (green) or **● Will be created** (yellow)
- Typed paths that don't exist are valid — FileSteward creates the folder at execution time

### Selection and bulk actions
- Checkbox on each finding row (custom-styled for visibility on dark backgrounds)
- Group-level "All" checkbox — checks/unchecks all visible findings in the group; shows indeterminate state when partially checked
- Dismissing a finding (✕) hides it without acting on it
- **Apply Selected** button activates when at least one finding is checked, showing the count

### Tree annotations
- Each tree node shows all applicable badges (a folder can have multiple findings)
- Parent folders show a **↓** indicator when a child has a finding (e.g. `naming ↓`, `empty ↓`)
- Clicking a tree node jumps to the corresponding finding in the list

---

## Dependency Chaining

When an approved action would cause a **direct parent folder** to become empty, FileSteward surfaces that parent as a dependent finding in the same session.

**Rule:** One level of cascade only. If removing folder A makes parent B empty, B is flagged as a dependent. B's parent is not automatically analyzed further — the post-apply re-scan handles the rest.

**UI treatment:**
- Dependent findings are shown inline below the triggering finding, visually linked
- Approving the trigger auto-stages the dependent (with a clear explanation)
- The user can break the link and keep the parent folder independently

**Example:** Archive (empty) → approved for removal → Old Projects (now empty) surfaced as dependent finding: *"Will become empty after Archive is removed. Remove Old Projects too?"*

**Rationale:** Full recursive cascade analysis creates unbounded edge cases. One-level cascade covers the most common and obvious case. The re-scan workflow handles the rest transparently.

---

## Conflict Resolution

Naming and move conflicts are detected at **Preview Changes time**, never mid-execution. If a conflict exists, the Preview screen flags it and blocks Apply until resolved.

**Conflict types:**
- Rename target already exists (e.g. `old_receipts` → `Old Receipts` but `Old Receipts` already exists)
- Move destination already contains a file or folder with the same name

**Resolution options presented to the user:**
- Choose a different name / destination
- Skip this action (leave as-is)
- Merge — only offered if both are folders, and only after showing the user what's inside each

Merge is never the default. The user must explicitly choose it.

---

## Staging and Quarantine

Two distinct concepts with different lifecycles:

**Staging (temp)** — exists only during a session. Proposed changes are assembled here for preview. Once the user approves and applies, staging is promoted to the target and disappears as a concept.

**Quarantine** — persists after the session. Removed folders and files are moved here rather than permanently deleted, so nothing is irreversible. Default location: `~/.filesteward/quarantine/`. The path is shown to the user in the Preview Changes screen before anything is moved.

Recovery from quarantine (browsing quarantined items, restoring to target) is deferred to Iteration 7, where it fits naturally alongside the review client. For Iteration 3, the quarantine location and execution log are the foundation for that future workflow.

---

## Simulation and Execution

Before any changes are applied, **Preview Changes** shows a simulation summary:
- Folders to be removed (with quarantine path shown)
- Folders to be renamed
- Files to be moved
- New folders to be created (from alternate location overrides)

The user confirms before execution. Removals go to quarantine (`~/.filesteward/quarantine/`), never permanently deleted.

---

## Post-Apply Re-scan

After changes are applied, FileSteward silently re-scans the **affected folders only** (not the full directory tree) in the background.

- If no new findings: "All clear. No new findings." — session closes cleanly
- If new findings: findings panel repopulates with second-pass results, labeled *"Found after applying changes"*
- Re-scan is scoped to affected folders and their immediate parents — not a full re-walk

This keeps the workflow uninterrupted while still catching cascading consequences (e.g. a parent folder becoming empty after a child is removed).

---

## Execution Log

One JSON log file per session, stored at `~/.filesteward/logs/`, named by session timestamp (e.g. `2026-03-28T14-32-00.json`).

Each log entry records:
- Action type (rename, move, remove)
- Source path
- Destination path or quarantine path
- Timestamp
- Outcome (success / skipped / conflict)

**Directory structure:**
```
~/.filesteward/
  quarantine/
    2026-03-28T14-32-00/     ← one folder per session, matches log timestamp
      Old Projects/
        Archive/
  logs/
    2026-03-28T14-32-00.json ← session log; references quarantine paths above
```

The session timestamp ties the log to its quarantine folder, giving the Iteration 7 recovery browser everything it needs to locate and restore quarantined items.

---

## What This Iteration Builds

1. **Folder scanner** — walk directory tree, collect structural metadata (depth, emptiness, naming, file types)
2. **Convention inference engine** — infer naming convention and file placement rules from the existing structure
3. **Finding generator** — produce typed findings with proposed actions
4. **Dependency chaining** — detect one-level cascades at analysis time
5. **Findings + tree UI** — two-panel review view with checkboxes, Finder-style tree, bidirectional selection
6. **Destination override** — inline path picker with exists/will-be-created indicator
7. **Conflict detection** — surface naming and move conflicts at Preview time
8. **Simulation mode** — preview all proposed changes before execution
9. **Execution** — apply approved actions; quarantine removals
10. **Post-apply re-scan** — silent background re-scan of affected folders
11. **Execution log** — JSON record of every action taken, keyed to quarantine folder

---

## What This Iteration Does Not Build

- iCloud-specific handling (evicted stubs, sync state on move)
- User-defined explicit rules (naming conventions, placement rules)
- Recursive cascade analysis beyond one level
- Quarantine recovery UI — deferred to Iteration 7
- Undo/revert UI — execution log is the foundation for this
- File content analysis (hashing, dedup) — covered in Iteration 4
- Configurable nesting depth threshold (hardcoded at 5) — deferred to wish list
- Near-empty folder detection (single-file folders) — deferred to wish list

# FileSteward: Iteration 5 Design — Consolidate Mode

## Status
Draft — for review before development begins.

---

## Context: The Three-Mode Model

FileSteward addresses personal file lifecycle management across three phases:

| Mode | Works On | Operations | Destructive? |
|------|----------|------------|--------------|
| **Clean** | Canonical operating directory | Find duplicates, propose removals, reorganize | Yes (with confirmation) |
| **Consolidate** | Backup archives → Canonical | Extract unique files, map to canonical structure, copy in | No — sources never touched |
| **Maintain** | Canonical operating directory | Ongoing dedup, archive old files, enforce rules | Yes (with confirmation) |

**Iteration 3 scope: Consolidate only.**

Clean and Maintain come later. Their shared characteristic (destructive operations on live directories) means they warrant a separate design pass with a stronger approval/undo model.

---

## The Consolidate Workflow

### Core concept

The canonical operating directory is not just the output destination — it is the **organizational schema**. FileSteward learns your folder structure from it and uses it to decide where new files should land.

You clean up your canonical directory first (manually, for now). Then FileSteward uses it as the template.

### Step-by-step flow

```
1. Designate canonical directory
   User points FileSteward at their primary organized folder
   (e.g. ~/Library/Mobile Documents/com~apple~CloudDocs)
   FileSteward indexes it: hashes all files, learns the folder tree

2. Add source archives
   User adds one or more backup folders to scan
   (existing multi-source scan capability, already built)

3. Analyze
   For each file in the sources, FileSteward determines:
   - Already in canonical (by hash)? → Skip, mark as PRESENT
   - Not in canonical (hash not found)? → Candidate for consolidation
   - Duplicate within the source archives themselves? → Keep one, mark rest as REDUNDANT

4. Review duplicate groups
   User opens duplicate groups and selects the canonical copy
   (the file to carry forward — by timestamp, size, path, or manual choice)

5. Map candidates to target structure
   FileSteward proposes where each candidate file should land in the output,
   based on the canonical directory's folder structure
   - Photos: match by year/month from EXIF or mtime
   - Documents: match by type and name patterns
   - Unknown: land in an /Unsorted/ staging area

6. Choose destination
   User selects where consolidated output lands:
   a. Offline archive folder (separate drive, not synced)
   b. iCloud unsynced folder (in iCloud but excluded from sync)
   c. Merge directly into canonical

7. Execute (copy, never move)
   FileSteward copies selected files to destination
   Sources are never modified
   An execution log records every copy operation

8. Export report
   Summary of what was copied, what was already present, what was skipped
   CSV or JSON
```

---

## Key Design Decisions

### 1. Canonical as schema, not just destination

The canonical directory's folder tree is the organizational model. When FileSteward maps a candidate file to an output path, it does so by matching the file's attributes (type, date, name) against the canonical tree's existing patterns.

**Example:** If canonical has `/Photos/2019/Vacation/` and `/Photos/2023/Christmas/`, a candidate photo from a backup dated December 2021 lands in `/Photos/2021/` (year match, new month folder created).

**Open question for discussion:** Should FileSteward *propose* a mapping and let the user adjust, or should it *ask* the user to define rules explicitly? Proposal: start with propose-and-adjust, add explicit rules in a later iteration.

### 2. Three duplicate states

Every file in the source archives gets one of three states:

| State | Meaning | Action |
|-------|---------|--------|
| `PRESENT` | Identical hash already in canonical | Skip — already safe |
| `UNIQUE` | Not in canonical, not duplicated in sources | Copy to output |
| `REDUNDANT` | Duplicate of another source file, one copy will be used | Carry one forward, discard rest |

### 3. Sources are read-only

FileSteward never writes to, moves files within, or deletes from the source backup archives. The only output is new files written to the chosen destination.

### 4. Destination options

| Option | Use case |
|--------|----------|
| Offline archive | Long-term storage on external drive, not synced anywhere |
| iCloud unsynced | Available on all devices via iCloud but excluded from active sync |
| Merge into canonical | Directly expand the canonical directory in place |

Offline archive is the safest default for a first consolidation pass.

### 5. Nothing is permanent until confirmed

Before any copy operation, FileSteward shows a simulation summary:
- N files would be copied
- N files already present (skipped)
- N redundant copies discarded
- Total storage freed / used

User confirms before execution.

---

## What This Iteration Builds

### New capabilities needed

1. **Canonical directory designation**
   - New UI to select and index a canonical folder
   - Stored separately from source scan folders

2. **File status classification**
   - Cross-reference source entries against canonical hashes → `PRESENT` / `UNIQUE` / `REDUNDANT`
   - Extend `ManifestEntry` or add a wrapper model for consolidation state

3. **Review UI for duplicate groups**
   - Open a duplicate group, see all copies
   - Select which copy to carry forward (keep one, discard rest)
   - Sort/filter by date, size, path

4. **Target path mapping**
   - Propose an output path for each `UNIQUE` file based on canonical structure
   - User can adjust proposed path before execution

5. **Destination selection**
   - UI to choose output location (offline, iCloud unsynced, or merge)

6. **Simulation mode**
   - Show what would happen before touching anything
   - Counts, sizes, proposed paths

7. **Copy execution**
   - Walk the approved file list, copy each to its proposed path
   - Streaming progress (same pattern as scan)
   - Write execution log (JSON)

8. **Export report**
   - CSV or JSON summary of the consolidation run

### What we're *not* building yet

- Clean mode (dedup/reorganize canonical in place)
- Maintain mode (ongoing enforcement rules)
- Undo / revert (tracked for later — execution log is the foundation)
- Similarity detection (name-match, image-match)
- User-defined mapping rules (explicit folder rules)

---

## Open Questions for Discussion

1. **How do you want to handle the canonical index?** Index it once and cache (same as source scans), or re-index on every consolidation run? Given iCloud sync, the canonical directory can change between sessions.

2. **Target path mapping depth:** Should FileSteward try to recreate the full relative path from the source archive, or map to canonical structure? E.g., `Born_Family_2000_01_24/photos/img001.jpg` — does the output path preserve `photos/img001.jpg`, or does FileSteward reclassify it to `Photos/2000/01/img001.jpg`?

3. **First consolidation destination:** For your specific use case, which destination do you want to test first — offline archive or iCloud unsynced?

4. **What does "clean up canonical first" look like in practice?** Do you want FileSteward to help with that (even minimally — just showing you the dupes in canonical), or are you comfortable doing it manually before running Consolidate?

---

## Suggested Iteration Breakdown

Given the scope, this could be two sub-iterations:

**3a — Review and classify**
- Canonical directory designation + indexing
- File status classification (PRESENT / UNIQUE / REDUNDANT)
- Review UI for duplicate groups (select canonical copy)

**3b — Map, simulate, copy, export**
- Target path mapping (propose + adjust)
- Simulation mode
- Copy execution + execution log
- Export report

Happy to adjust scope based on your input.

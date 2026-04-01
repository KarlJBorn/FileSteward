# FileSteward — Product Definition

## The Problem

Years of backup copies, drive migrations, and ad-hoc archiving leave two distinct messes:

1. **Many copies of the same thing** — five versions of `Born_Family` scattered across drives, each slightly different, none authoritative.
2. **One copy that's grown messy** — a single folder that has accumulated empty directories, naming drift, and forgotten junk over time.

These look similar but require fundamentally different tools.

---

## FileSteward Consolidate

### What it does
Takes multiple similarly-structured source directories and produces one canonical output directory. The latest (or user-nominated) source is the starting point; non-duplicate content from the other sources is folded in. The result is a single, complete directory that supersedes all the inputs.

### What it does not do
- It does not modify any source directory.
- It does not swap anything. The output is a new directory.
- It does not clean up naming or folder structure (that is Maintain's job).

### What "done" looks like for a user
> "I had Born_Family on three different drives. I ran Consolidate, pointed it at all three, and now I have one Born_Family with everything in it. Nothing is missing. I can archive or delete the originals."

### Key operations
1. User selects 2+ source directories
2. Engine walks all sources, fingerprints every file (SHA-256)
3. User nominates (or engine infers) the primary source — the starting point for the output
4. Engine identifies files in secondary sources not present in the primary (by hash)
5. User reviews: which unique files to fold in, which to skip
6. Engine builds the output directory
7. Done — no swap

### Open questions
- How does the engine infer the primary source? (newest folder mtime? most files? user pick?)
- What happens with files that exist in multiple sources with different names but identical content?
- Does folder structure from secondary sources get preserved, or flattened into the primary's structure?

---

## FileSteward Maintain

### What it does
Takes a single directory, analyses its structure, and produces a rationalized version of it. Empty folders, naming inconsistencies, and misplaced files are flagged. The user reviews proposed changes, a clean copy is built, and when the user is satisfied the copy swaps in to replace the original.

### What it does not do
- It does not merge content from other directories.
- It does not modify the source until the user explicitly confirms the swap.
- It does not resolve duplicates across multiple locations (that is Consolidate's job).

### What "done" looks like for a user
> "My Photos folder had 40 empty folders and inconsistent naming going back 15 years. I ran Maintain, reviewed the proposals, tweaked a few, and swapped. The folder is clean. The old version is still there as Photos.OLD if I need to recover anything."

### Key operations
1. User selects one source directory
2. Engine walks and fingerprints; generates findings (empty folders, naming drift, excessive nesting)
3. User reviews side-by-side Original / Target tree; accepts, rejects, or manually marks folders
4. Engine builds rationalized copy alongside source
5. User reviews build stats; confirms swap
6. Source renamed to `source.OLD`; copy renamed to `source`

### Current status — Iteration 4 complete (v0.4.0)
**This is what FileSteward builds today.** The rationalize screen, copy-then-swap execution model, naming engine, and duplicate file resolution are all Maintain.

Completed capabilities:
- Side-by-side Original / Target directory tree with collapse/expand
- Structural findings: empty folders, naming inconsistencies, excessive nesting, misplaced files
- SHA-256 duplicate detection: groups identical files by hash
- Penalty-based ranker: auto-resolves most duplicate groups; flags ambiguous groups for user decision
- Duplicate resolution panel: shows auto-resolved summary + per-group keeper selection for ambiguous cases
- Apply is blocked until all ambiguous groups are resolved
- Build step omits non-kept duplicate copies from the rationalized output
- Atomic swap: source renamed to `.OLD`; rationalized copy takes source name

---

## Shared Foundation

Both products run on the same Rust engine:

| Capability | Consolidate | Maintain | Status |
|---|---|---|---|
| Recursive directory walk | ✓ | ✓ | ✅ Done |
| SHA-256 file fingerprinting | ✓ | ✓ | ✅ Done |
| Exact duplicate detection (group by hash) | ✓ | ✓ | ✅ Done |
| Penalty-based duplicate ranker | ✓ | ✓ | ✅ Done |
| Naming convention analysis | — | ✓ | ✅ Done |
| Build (copy with transformations) | ✓ | ✓ | ✅ Done |
| Swap | — | ✓ | ✅ Done |
| Multi-source walk + fold-in | ✓ | — | Iteration 5 |
| Rust library restructure (#79) | ✓ | ✓ | Iteration 5 |

---

## Delivery model

**Option A — One app, two modes**
Single FileSteward app. Home screen asks: "Consolidate directories" or "Maintain a directory." Mode is set by intent, not inferred from selection count.

**Option B — Two apps, shared framework**
FileSteward Consolidate and FileSteward Maintain ship separately, sharing the Rust core as a library. Cleaner product story; more distribution complexity.

**Recommendation:** Start with Option A. The shared infrastructure isn't mature enough yet to split cleanly. Revisit at 1.0.

---

## What this means for the roadmap

**Iteration 4 is complete.** Maintain v0.4.0 ships with full duplicate detection and resolution.

**Iteration 5 — Consolidate v1** is next. The main screen will need a mode selector or a second
entry point. Multi-folder selection (#38), the shared Rust library restructure (#79), and the
Consolidate engine are all in scope. Design those features against this definition.

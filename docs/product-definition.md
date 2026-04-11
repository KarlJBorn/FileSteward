# FileSteward Consolidate — Product Definition

## The Problem

Years of backup copies, drive migrations, and ad-hoc archiving leave the same collection
scattered across multiple drives — five versions of `Born_Family`, each slightly
different, none authoritative. Consolidate solves this: one canonical output, nothing
missing, sources untouched.

---

## What it does

Takes multiple similarly-structured source directories and produces one canonical output
directory. All sources are peers — there is no primary. The engine rationalises folder
structure, removes duplicates, resolves naming conflicts, and builds the output. The user
reviews and confirms before anything is written.

## What it does not do
- It does not modify any source directory.
- It does not swap anything. The output is a new directory.
- It does not delete files — duplicates are simply omitted from the output.
- It does not run without user review and confirmation.

## What "done" looks like for a user
> "I had Born_Family on three different drives. I ran Consolidate, pointed it at all
> three, reviewed the proposed output, and built it. Now I have one Born_Family with
> everything in it, duplicates removed, folder structure clean. I can archive or delete
> the originals."

---

## Key operations

1. User selects 2+ source folders (all treated as peers — no primary/secondary)
2. **Scan 1 — Structure scan (no hashing):** engine walks all sources, counts files and
   types, detects shared folder structures
3. User filters — excludes file types and folders via navigable source and target trees
4. **Scan 2 — Content scan (full SHA-256):** engine hashes all non-excluded files,
   deduplicates by content hash, detects naming collisions and placement ambiguities,
   produces a routing plan
5. User reviews — side-by-side source and proposed target trees, color-coded; resolves
   ambiguities and collisions before build is unlocked
6. Engine builds the output directory from the approved routing plan
7. Done — no swap

---

## Design principles
- Safety over cleverness — default to analyse, recommend, confirm; never default to destructive action
- Explainability over magic — every recommendation shows its basis (same hash, naming pattern, etc.)
- Rust owns all execution — all filesystem operations performed by the Rust engine; Flutter is UI only
- Desktop first — macOS primary; Windows 11, iPadOS, iPhoneOS targeted

---

## Shared Rust engine capabilities

| Capability | Status |
|---|---|
| Recursive directory walk | ✅ Done |
| SHA-256 file fingerprinting | ✅ Done |
| Exact duplicate detection (group by hash) | ✅ Done |
| Penalty-based duplicate ranker | ✅ Done |
| Naming convention analysis | ✅ Done |
| Build (copy with transformations) | ✅ Done |
| Structure scan (no hashing) | ✅ Done |
| Content scan with routing plan | ✅ Done |
| Overridden path support (include despite extension exclusion) | ✅ Done |

---

## Related documents
- `docs/maintain-product-definition.md` — FileSteward Maintain (future separate product)
- `CLAUDE.md` — development guidance, iteration plan, architecture

# FileSteward Maintain — Product Definition

## What it does

Periodically reviews a single operating disk (e.g. `/Users/username`) for duplicates,
poor directory structure, and outdated or untouched files. Flagged files are moved to a
backup folder — never deleted outright. AI-assisted pattern recognition identifies files
that haven't been opened in years, redundant downloads, and structural drift. The user
reviews and approves each recommendation before anything moves.

## What it does not do
- It does not merge content from multiple sources (that is Consolidate's job).
- It does not delete files — it archives them to a user-nominated backup location.
- It does not run automatically without user review and approval.

## What "done" looks like for a user
> "I ran Maintain on my home folder. It found 4,200 duplicate files, 800 files untouched
> since 2011, and three nested backup folders I'd forgotten about. I reviewed the list,
> approved most of it, skipped a few edge cases, and kicked it off. Everything flagged
> moved to an archive folder. My disk has 18GB back."

## Key operations
1. User selects their operating disk or home folder
2. Engine walks and fingerprints; identifies duplicates, structural problems, stale files
3. AI layer flags candidates by age, access patterns, and redundancy signals
4. User reviews recommendations (side-by-side, grouped by category)
5. Engine moves approved files to backup folder — no deletions
6. Summary report of what moved and where

## Relationship to Consolidate
Maintain reuses the Consolidate engine's core capabilities (walking, hashing, duplicate
detection, penalty scoring). It is a separate product with a separate UI optimised for
the periodic-review use case. Future work — not in current scope.

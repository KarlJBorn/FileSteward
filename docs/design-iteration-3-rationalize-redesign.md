# FileSteward: Iteration 3 Rationalize Screen — Redesign

## Status
Approved. Ready for implementation.

**Supersedes:** [`design-iteration-3.md`](design-iteration-3.md) (UI design section only — engine, execution, and log design remain valid)

**Anchor issues:** [#44](https://github.com/KarlJBorn/FileSteward/issues/44) (before/after tree), [#46](https://github.com/KarlJBorn/FileSteward/issues/46) (right-click context menu)

---

## Why the Original Design Was Superseded

The original Rationalize screen (findings list on the left, annotated folder tree on the right) was designed and built before testing against real data at scale.

Real-world testing against `Born_Family_2000_01_24` — a Windows 98 backup with 200+ folders and 181 findings — exposed fundamental problems:

- The findings list became overwhelming at scale; grouping by type didn't reduce cognitive load enough
- The tree panel only showed folders referenced by findings, not the full directory — users lost spatial context
- Color-coded badges on the tree were hard to read when most rows had findings
- There was no clear sense of "what will this directory look like after I approve these actions"
- The two panels were complementary views of the same thing, not a clear before/after narrative

The core user need is not "show me a list of problems" — it is "show me what I'm starting with and what it will look like when I'm done." The original design didn't answer that question.

---

## The Decision: Before/After Directory Trees

The Rationalize screen becomes two side-by-side directory tree panels showing the same folder hierarchy in two states.

### Left panel — Original state
- Full directory tree of the selected folder, all folders visible
- Colour-coded by finding:
  - **Red** — proposed removal
  - **Orange** — proposed rename
  - **Blue** — proposed move
- Clean/unflagged folders shown without colour
- All files visible alongside folders

### Right panel — Target state
- Computed representation of the directory after all currently-approved actions are applied
- Folders proposed for removal are **absent** (not greyed out, not struck through — simply not there)
- Renamed folders shown in the new name, **green italic**
- Moved folders appear at their destination
- Files visible alongside folders, same as left

### Synchronized scrolling
- Scrolling either panel scrolls both simultaneously, keeping rows aligned
- Allows direct visual comparison of any part of the tree

### Detail drawer
- Clicking any row (in either panel) slides up a drawer showing:
  - The finding type and inference basis ("why is this flagged?")
  - Proposed action and editable proposed name (for renames)
  - Accept / Reject / Skip actions
- Drawer does not navigate away from the tree — tree stays visible behind it

---

## Key Decisions and Rationale

### Why two panels instead of a single annotated tree?

A single tree with annotations (badges, strikethroughs, colour highlights) forces the user to mentally simulate the result. Two panels make the simulation explicit. The user can scan the right panel and answer "is this what I want?" without any mental effort.

**Alternative considered:** Single tree with a toggle between before/after state. Rejected because toggling breaks spatial comparison — you lose the ability to hold both states in view simultaneously.

### Why are removed folders absent in the right panel rather than shown with strikethrough?

Strikethrough draws attention to what's being removed, which inverts the intended reading direction. The right panel is the *answer* — what the directory will look like. Absent folders are simply not part of that answer. The user should be reading the right panel as a destination, not as a diff.

**Alternative considered:** Show removed folders in red strikethrough in the right panel. Rejected because it clutters the target state view and makes it harder to assess whether the result is correct.

### Why synchronized scrolling rather than independent scrolling?

The value of two panels is spatial comparison — left row N should always be adjacent to right row N. Independent scrolling breaks the alignment and forces the user to manually re-sync, which defeats the purpose.

**Risk acknowledged:** When removed folders create gaps in the right panel, row alignment between panels breaks. This is a known problem. The design accepts the misalignment as the honest representation of what's happening — folders are genuinely absent — rather than inserting placeholder rows to maintain alignment. This is the primary open design question (see below).

### Why a right-click context menu (Issue #46)?

The engine produces findings based on inference. But users may want to mark folders that the engine didn't flag — for example, a folder the user knows is redundant but doesn't match any structural pattern. Right-click gives users the ability to initiate actions on any folder, not just engine-flagged ones.

This reinforces the design principle: the engine proposes, the user decides. The user is not limited to approving or rejecting engine suggestions — they can originate actions themselves.

### Why build in Flutter rather than validating in a static HTML mockup first?

A static mockup would answer visual design questions but not the performance questions at real scale. Flutter's `ListView.builder` virtualizes large lists — the only way to know if 1000+ rows stays performant is to run it natively. Building in Flutter means the work goes directly into the codebase rather than being discarded after validation.

---

## Design Decisions (resolved in planning)

### 1. Row alignment when right panel has gaps
**Decision: Drop synchronized scrolling. Right panel is its own clean view.**

When a folder is absent from the right panel, rows shift up and alignment with the left panel breaks. Rather than hiding this with placeholder rows or accepting a broken spatial mirror, the right panel stands on its own terms — a clean representation of the target state, not locked to the left panel's row positions. Synchronized scrolling is removed. Each panel scrolls independently.

Rationale: if alignment breaks at the first removal, synchronized scrolling is already misleading. A clean independent right panel is more honest and less confusing. Complexity can be added in a future iteration if users find the panels hard to cross-reference.

### 2. Files in both panels
**Decision: Files collapsed by default. Folders shown first, files visible on demand via expand toggle.**

The Rationalize screen is about folder structure. File-level actions are Iteration 4. Showing thousands of files by default at 200+ folders makes the tree unreadable. Users expand a folder to see its files when they need to.

Files are not colour-coded and not interactive in this iteration.

Also filed: [#51](https://github.com/KarlJBorn/FileSteward/issues/51) — lone file in single-purpose folder as a future finding type.

### 3. Colour palette
**Decision: Named constants from day one, tuned after real-data validation.**

The three finding colours (red=remove, orange=rename, blue=move) are defined as named constants rather than inline values, so the entire palette is a one-line change. Legibility will be validated by running against `Born_Family_2000_01_24` (200+ folders, 181 findings) and tuning from there.

---

## Related Issues Filed During Planning

| # | Summary |
|---|---------|
| [#35](https://github.com/KarlJBorn/FileSteward/issues/35) | Sort file type list in Scan Scope card |
| [#36](https://github.com/KarlJBorn/FileSteward/issues/36) | Rationalize should inherit already-selected folder |
| [#37](https://github.com/KarlJBorn/FileSteward/issues/37) | Clarify main screen flow and button sequencing |
| [#38](https://github.com/KarlJBorn/FileSteward/issues/38) | Folder picker doesn't allow multi-selection |
| [#40](https://github.com/KarlJBorn/FileSteward/issues/40) | Exclude known system/junk folder patterns from scan |
| [#41](https://github.com/KarlJBorn/FileSteward/issues/41) | Bulk dismiss findings by folder subtree |
| [#44](https://github.com/KarlJBorn/FileSteward/issues/44) | Redesign: side-by-side before/after directory trees (anchor) |
| [#45](https://github.com/KarlJBorn/FileSteward/issues/45) | E/D/N/M badges look like buttons but aren't |
| [#46](https://github.com/KarlJBorn/FileSteward/issues/46) | Right-click context menu for user-initiated folder actions |
| [#47](https://github.com/KarlJBorn/FileSteward/issues/47) | Path-relationship heuristics and folder cascade logic |
| [#48](https://github.com/KarlJBorn/FileSteward/issues/48) | Candidate rules catalog for duplicate resolution |

---

## What Must Be Resolved Before Implementation Starts

1. **Row alignment decision** (open question #1 above) — prototype the gap behaviour before committing to the layout approach
2. **File display rules** (open question #2) — agree on whether files are collapsed by default
3. **Colour palette** — validate legibility against a real scan output at 200+ folders
4. **Detail drawer design** — the trigger (click vs hover), the fields shown, the Accept/Reject/Skip interaction

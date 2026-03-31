# FileSteward: Iteration 3 Rationalize Screen — Redesign

## Status
Approved. Ready for implementation — supersedes all prior versions of this doc.

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

### Right panel — Target state (Panel B)
- Computed representation of the directory after **all engine-proposed actions are applied by default**
- The user reviews the target state and **rejects** what they don't want — rejection is the exception, not the rule
- Folders proposed for removal are **absent** (not greyed out, not struck through — simply not there)
- Renamed folders shown in the new name, **green italic**
- Moved folders appear at their destination
- Rejected findings cause the affected folder to reappear in the right panel

### Why Panel B (all-changes-applied by default) rather than Panel A (accept-only)?

Panel A (right panel only reflects explicitly accepted changes) was the first implementation. Real-data testing showed that at 181 findings the right panel looked nearly identical to the left because nothing had been accepted yet — defeating the purpose of the two-panel layout.

The right panel's value is showing the destination. Panel B delivers that immediately. The user's primary task becomes scanning the right panel and asking "is this what I want?" — not working through a list of 181 individual accept clicks.

Panel B does not violate the "system never assumes consent" principle. The user is explicitly clicking "Accept All" or "Apply" — they are consenting to the result they see in the right panel. Quarantine provides the safety net: nothing is permanently deleted.

### Synchronized scrolling
Removed. Each panel scrolls independently.

### Detail drawer
- **Trigger:** single click on any flagged row in either panel
- **Fields:**
  - Finding type and severity
  - Folder's current name and full path
  - Proposed action (rename to X / move to Y / remove)
  - Inference basis — one plain-English sentence (e.g. *"90% of sibling folders use Title Case"*)
  - For renames: editable field pre-populated with the suggested name
- **Actions:** Accept / Reject — equal weight, no default
  - **Accept** — confirms the engine's proposal for this finding
  - **Reject** — removes the finding's effect from the right panel; folder reappears in target state
  - Closing the drawer without choosing leaves the finding at its default (applied) state
- Drawer closes after any action. Clicking the same row again reopens it showing the current decision with option to change it
- Tree remains visible behind the drawer — no navigation away

---

## Key Decisions and Rationale

### Why two panels instead of a single annotated tree?

A single tree with annotations forces the user to mentally simulate the result. Two panels make the simulation explicit. The user can scan the right panel and answer "is this what I want?" without any mental effort.

**Alternative considered:** Single tree with a toggle between before/after state. Rejected because toggling breaks spatial comparison.

### Why are removed folders absent in the right panel rather than shown with strikethrough?

The right panel is the *answer* — what the directory will look like. Absent folders are simply not part of that answer.

### Why Accept All?

At real data scale (181 findings), requiring individual Accept for each finding is a chore that defeats the purpose of the tool. The engine's findings are pattern violations against the folder's own conventions — not ambiguous guesses. The user should be reviewing the *result* (right panel), not ratifying a list of operations.

Accept All is appropriate here because:
- Quarantine provides a safety net — nothing is permanently deleted
- The right panel shows the full result before Apply is pressed
- Reject is always available for individual exceptions

**Decision: "Accept All" button in the bottom bar alongside "Apply". Apply executes whatever is currently reflected in the right panel (all non-rejected findings + user-initiated removals).**

### Why a right-click context menu (#46)?

Users may want to mark folders the engine didn't flag. Right-click gives users the ability to initiate removals on any folder in the left panel.

### System folder handling (#57)

Two categories handled differently:

**GUID-named folders** (e.g. `{4ABEA880-9E0C-11D3-A946-00A0CC51A5BD}`):
- Pattern: `{8hex-4hex-4hex-4hex-12hex}`
- Decision: **Option A — skip entirely during scan.** Never appear in tree or findings.
- Rationale: COM/OLE registration artifacts. Categorically not user data. No individual judgment needed.

**Named Windows/macOS system folders** (e.g. `Application Data`, `Recent`, `NetHood`, `PrintHood`, `Cookies`, `.DS_Store`, `.Spotlight-V100`):
- Decision: **Option B — surface as a distinct `system_folder` finding type, action: remove, severity: warning.**
- Shown as a group in the left panel; absent from the right panel by default (Panel B).
- A single "Remove all system folders" affordance handles the common case.
- Individual reject still available.

---

## Design Decisions (resolved)

### 1. Row alignment when right panel has gaps
**Decision: Drop synchronized scrolling. Right panel is its own clean view.**

### 2. Files in both panels
**Decision: Files collapsed by default. Folders shown first, files visible on demand via expand toggle.**

Files are not colour-coded and not interactive in this iteration.

### 3. Colour palette
**Decision: Named constants from day one, tuned after real-data validation.**

red=remove (`_kRemoveColor`), orange=rename (`_kRenameColor`), blue=move (`_kMoveColor`), green italic=rename target (`_kRenameTargetColor`).

### 4. Right panel default state (Panel B)
**Decision: Right panel shows all engine-proposed changes applied by default. Reject reverts individual findings.**

### 5. Accept All
**Decision: "Accept All" button in bottom bar. Apply executes whatever the right panel currently reflects.**

### 6. System folders
**Decision: GUID folders skipped in scan (Option A). Named system folders flagged as `system_folder` finding type (Option B).**

---

## Related Issues

| # | Summary |
|---|---------|
| [#35](https://github.com/KarlJBorn/FileSteward/issues/35) | Sort file type list in Scan Scope card |
| [#36](https://github.com/KarlJBorn/FileSteward/issues/36) | Rationalize should inherit already-selected folder |
| [#37](https://github.com/KarlJBorn/FileSteward/issues/37) | Clarify main screen flow and button sequencing |
| [#38](https://github.com/KarlJBorn/FileSteward/issues/38) | Folder picker doesn't allow multi-selection |
| [#40](https://github.com/KarlJBorn/FileSteward/issues/40) | Exclude known system/junk folder patterns from scan (superseded by #57) |
| [#41](https://github.com/KarlJBorn/FileSteward/issues/41) | Bulk dismiss findings by folder subtree |
| [#44](https://github.com/KarlJBorn/FileSteward/issues/44) | Redesign: side-by-side before/after directory trees (anchor) |
| [#46](https://github.com/KarlJBorn/FileSteward/issues/46) | Right-click context menu for user-initiated folder actions |
| [#47](https://github.com/KarlJBorn/FileSteward/issues/47) | Path-relationship heuristics and folder cascade logic |
| [#48](https://github.com/KarlJBorn/FileSteward/issues/48) | Candidate rules catalog for duplicate resolution |
| [#57](https://github.com/KarlJBorn/FileSteward/issues/57) | System folder detection: GUID folders + named Windows/macOS shell folders |

---

## What Must Be Resolved Before Next Implementation

All design questions resolved. Next implementation increment:
1. Panel B (right panel shows all changes by default, reject reverts)
2. Accept All button
3. Right-click "Mark for removal" on any left-panel folder (#46)
4. System folder detection in Rust (#57): GUID skip + `system_folder` finding type

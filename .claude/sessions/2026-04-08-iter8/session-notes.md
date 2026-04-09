# Iteration 8 Session Notes
**Date:** 2026-04-08  
**Branch:** iter8-two-panel-tree  
**PR:** #123

## Design Discussions

### Build Hang Investigation
- **Initial hypothesis:** Large JSON payloads blocking UI thread when writing to pipe
- **Discovery:** Dart's IOSink is non-blocking; issue was overstated
- **Resolution:** Closed as "not a real issue" — `jsonEncode()` may cause brief stutter but not a hang
- **Lesson:** Test assumptions against actual behavior before designing fixes

### Path Truncation Design
- **Problem:** Duplicate group paths shown as `…/folder/file.jpg` insufficient for decision-making
- **Solution:** Two-line format: bold filename (line 1), full muted path (line 2), no truncation
- **Why:** Filename is the focus; full path provides context without overwhelming display
- **Rationale over alternatives:** 
  - Considered: single-line with wrapping (cluttered)
  - Considered: tooltip on hover (hidden by default, less discoverable)
  - Chose: always-visible two-line format for clarity

### Bulk Folder Preference Design
- **User need:** Right-click on a file path to bulk-apply a preference across multiple groups
- **Two operations emerged:**
  - "Prefer [Folder] for all groups" — sets keeper for groups containing that folder; others unresolved
  - "Consolidate into [Folder]" — sets keeper for groups with that folder, auto-resolves B/C-only groups
- **Why two?** Users may want different behaviors: cautious preference (first op) vs. aggressive consolidation (second op)
- **Design insight:** User wants to "fold everything into one source" — this is consolidation orchestration, not just duplicate resolution

### Type-based Routing Discovery
- **Context:** User mentioned "consolidate all photos into Pictures folder, videos into Movies, music into Music"
- **Key insight:** Folder context (OS wrappers) should take precedence over extension
  - `My Documents/scan.jpg` → `Documents/scan.jpg` (not `Pictures/`)
  - Respects user's intentional file placement
- **Unknown extensions:** Gate with >10 file threshold; force user decision
- **Why important:** Cleanly organizes output; user mental model is "by type"

### Wrapper Folder Promotion Design
- **Problem observed:** My Pictures / My Pictures 2012 preserved as separate top-level folders instead of merging
- **Solution:** Detect wrappers (known names + structural heuristic), propose merges at Review time, apply at Build time
- **Critical insight:** Wrapper detection is folder structure analysis, not file-level deduplication
- **Two routing modes:** 
  - Wrapper with year subfolders (2000/, 2001/) → merge into canonical Pictures/
  - Wrapper with no years (just files) → becomes date subfolder (Pictures/2012/)

### Flow Architecture Issue (Key Finding)
- **Real issue discovered during UI testing:** Current 3-step Review flow doesn't match user's mental model
- **User mental model:** 
  1. Scan → understand structure, exclude types
  2. Review folder structures → see duplicates, suggest rationalization
  3. Resolve folder ambiguities
  4. Review duplicate files
  5. Review filename conflicts
  6. Final target structure review
  7. Build
- **Current reality:** Jump straight to duplicate groups without folder structure review first
- **Impact:** Became clear that path truncation + bulk preference are features, but they don't fix the fundamental flow issue
- **Decision:** Redesign entire Review phase for Iteration 9

## Alternatives Considered

| Topic | Option A | Option B | Chosen | Why |
|-------|----------|----------|--------|-----|
| Path display | Single line + wrapping | Two lines: filename + path | Two lines | Always visible, clear visual hierarchy |
| Bulk preference | Single "Prefer" operation | Two operations (Prefer + Consolidate) | Two operations | Different user needs for different scenarios |
| Folder context | Extension-only routing | Context > extension | Context > extension | Respects user intent (My Documents/photo.jpg stays in Documents) |
| Unknown extensions | Auto-route to Documents | Gate with >10 threshold | Gate with threshold | Forces user to be explicit about intent |
| Wrapper detection | Structural heuristic only | Known names + structural | Both | Covers common cases (fast) + novel patterns |

## User Feedback from UI Testing

**Positive:**
- Path truncation works correctly ✅
- Right-click bulk operations work correctly ✅
- Filter step works well ✅
- Scope filtering reduces file count as expected ✅

**Issues identified:**
- Review step order is wrong — user should see folder structures before duplicates
- Undo toast not dismissing automatically (bug)
- File types should be pre-excluded more aggressively
- File type ribbon should be alphabetically sorted
- Target directory structure should be visible before build (currently missing)

**Nice-to-haves:**
- File preview for known types (doc, rtf, etc.)
- Alphabetical sorting of extension ribbon

## Key Insights

1. **Design needs user validation early** — We designed features that work technically but don't address the real user flow issue
2. **"Getting lost on flow"** — Focused on individual features without understanding the orchestration
3. **Testing reveals truth** — Only UI testing with real data showed the 3-step flow was insufficient
4. **Wrapper folders are structural, not deduplication** — Different mental model than duplicate file resolution
5. **Type-based routing is a consolidation strategy** — Not just file organization, but a fundamental way to present output

## Process Observations

- Design sessions locked four features but didn't design the overall Review architecture
- Mid-thread context decay: as thread got longer, focus drifted from holistic flow to individual features
- Conversational insights (6-step flow discovery) only captured at the very end
- Handoff is incomplete without rationale for each design decision

## Lessons for Iteration 9

1. **Comprehensive flow design first** — Lock the 6-step Review architecture before designing individual features
2. **Capture insights immediately** — Don't wait until end of session to record "aha moments"
3. **Use checkpoints** — Save mid-task state regularly to prevent context loss
4. **Validate with user frequently** — Don't wait for end-of-iteration testing to discover flow issues
5. **Document rationale** — "Why we chose X" matters as much as "what X is"

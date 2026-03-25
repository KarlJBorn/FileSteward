# FileSteward Design Principles

These principles guide every product and engineering decision in FileSteward.
They are living guidance — updated as we learn from real data and real users.

---

## Safety over cleverness
Default to analyze, recommend, quarantine, confirm.
Never default to destructive action. A user should never lose a file because
FileSteward made an assumption.

## Explainability over magic
Every recommendation must show its basis — same hash, newer timestamp, path
normalization rule, user decision history. A human should always be able to
understand why FileSteward proposed something, and override it.

## Confidence-based review
Every proposed action carries a confidence level:

| Confidence | Example | Approach |
|------------|---------|----------|
| High | Exact hash match, same canonical path | Auto-propose, minimal review |
| Medium | Same hash, different path / same path, different hash | Flag for review with explanation |
| Low | Structural pattern match, no hash confirmation | Show reasoning, require approval |
| Suggestion | AI-assisted classification | Clearly labeled, never auto-applied |

The three user-facing complexity levels (same structure / same logical structure /
differing logical structure) are a simplification of this confidence spectrum —
not an engineering boundary.

## Human checkpoints between passes
FileSteward works in passes, each with a human sign-off before proceeding:

1. **Inventory** — scan all sources, build persistent manifests
2. **Normalize** — resolve path variations into canonical structure; confirm rules
3. **Exclude** — prune folder types and file types you don't want carried forward
4. **Deduplicate** — find exact and near duplicates within the normalized set
5. **Propose** — present the final structure for review and approval before anything moves

FileSteward never advances to the next pass automatically.

## The archive is a first-class citizen
The canonical archive produced by a consolidation is a persistent, indexed,
queryable artifact — not just a folder on disk. FileSteward maintains:

- A manifest of every file in the archive and where it came from
- A decision log of what was kept, discarded, and why
- Enough information to run future rationalizations against the archive as a baseline

This makes FileSteward useful beyond the initial consolidation. A year later,
when you have new material to rationalize, FileSteward compares against your
known archive and tells you exactly what's new, what's a duplicate, and what's
a newer version of something you already have.

## Iterate to the output
Don't over-specify the final output structure upfront. Let real data and trial
runs inform the right shape. The first consolidation will teach us more than
any amount of design work in the abstract.

## Privacy by design
FileSteward handles decades of personal files — tax records, financial documents,
family correspondence. Privacy is an architectural requirement, not an afterthought:

- No file names or content are sent to external services without explicit user consent
- An anonymization layer substitutes real names with tokens before any cloud AI call
- A local model option (on-device, no network) is a supported configuration
- An air-gapped mode disables all network calls; AI features fall back to rules only
- Users are shown exactly what would be sent before any external call is made

## Engine first, UI second
The Rust core must be fully testable from the CLI independent of any UI. Every
capability FileSteward exposes in the UI must be exercisable via the Rust binary
and inspectable via its JSON output.

## Designed to grow
FileSteward starts with exact duplicate detection and grows toward:
- Path normalization rules (user-visible, user-editable)
- AI-assisted classification for ambiguous cases
- Ongoing archive stewardship across multiple rationalization sessions

Each iteration adds capability without breaking the simpler use cases.

# FileSteward — Product Wish List

Features explicitly deferred from iteration scope. Revisit when prioritizing future iterations.

---

## Directory Rationalization

### Near-empty folder detection
Flag folders containing only one real file (excluding system metadata). Potentially noisy — a single file in a folder may be intentional. Suggested treatment when implemented: low-severity "Notice" category, collapsed by default in the findings list.

---

## AI-Powered Increments

### Semantic token classification for naming inference
Rule-based naming convention inference skips ambiguous cases (e.g. `OLD_files` — is `OLD` an acronym or a stylistic choice?). A future AI increment could use a language model to classify tokens semantically, enabling confident rename proposals for cases the rule engine defers on.

### Naming convention inference beyond clear-cut cases
Related to above — AI could handle brand names, mixed conventions, and culturally specific naming patterns that heuristics can't reliably detect.

---

## Quarantine & Recovery

### Quarantine browser (Iteration 7 candidate)
UI for browsing items moved to quarantine in prior sessions, with restore-to-target action. Foundation (quarantine location + execution log) is established in Iteration 3. Full recovery UI planned for Iteration 7.

---

## Settings

### Settings window
A dedicated settings UI for user-configurable preferences. Candidates for initial settings:
- Nesting depth threshold (default: 5 levels, hardcoded in Iteration 3)
- Quarantine location override
- Convention inference sensitivity

---

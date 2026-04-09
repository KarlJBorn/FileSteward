# Session Archive

Each iteration gets a session directory containing the complete design process, decisions, and learnings.

## Structure

```
.claude/sessions/
├── YYYY-MM-DD-iter-N/
│   ├── session-notes.md          # Design discussions, rationale, alternatives considered
│   ├── checkpoint-history.md     # Task checkpoints from the session
│   ├── decisions-locked.md       # Final designs locked in CLAUDE.md with context
│   └── retrospective.md          # What worked, what didn't, lessons learned
├── 2026-04-08-iter8/
│   ├── session-notes.md
│   ├── checkpoint-history.md
│   ├── decisions-locked.md
│   └── retrospective.md
```

## Purpose

- **Continuity across threads:** Next iteration's thread reads these files to understand design decisions and rationale
- **Design process capture:** Documents "why" not just "what"
- **Retrospectives:** Sessions end with lessons learned for future iterations
- **Context preservation:** If context is lost mid-thread, checkpoint-history.md provides rollback point

## For Each Thread

Before starting an iteration:
1. Read `.claude/sessions/[previous-iteration]/session-notes.md` for design context
2. Read `.claude/sessions/[previous-iteration]/retrospective.md` for lessons learned

During an iteration:
1. Update `TASK_CHECKPOINT.md` in project memory every 45 minutes
2. Keep running notes in session-notes.md of design discussions
3. When a design is locked, add it to decisions-locked.md with rationale

After an iteration:
1. Commit session directory to GitHub
2. Write retrospective.md with lessons learned
3. Prepare handoff prompt for next thread

## Files

- **session-notes.md** — Design discussions, alternatives considered, "aha moments", user feedback, design rationale
- **checkpoint-history.md** — Sequence of task checkpoints showing progress through the iteration
- **decisions-locked.md** — Final designs with context on why each was chosen over alternatives
- **retrospective.md** — What worked, what didn't, process improvements, handoff notes for next iteration

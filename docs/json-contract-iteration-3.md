# FileSteward: JSON Contract — Iteration 3

This document defines the complete JSON interface between the Rust engine and Flutter UI for Iteration 3 (Directory Rationalization). Both sides must conform to these shapes exactly.

---

## Overview

There are four message types:

| # | Direction | When |
|---|-----------|------|
| 1 | Rust → Flutter | Progress during scan |
| 2 | Rust → Flutter | Findings payload (scan complete) |
| 3 | Flutter → Rust | Execution plan (user-approved actions) |
| 4 | Rust → Flutter | Execution result |

All messages are JSON. Messages 1 and 2 are emitted to stdout as newline-delimited JSON (one JSON object per line), consistent with the Iteration 2 streaming pattern. Message 3 is passed to Rust via stdin. Message 4 is emitted to stdout on execution completion.

---

## 1. Progress Message (Rust → Flutter)

Emitted repeatedly during directory walk, before findings are ready.

```json
{
  "type": "progress",
  "folders_scanned": 147,
  "current_path": "Work/Projects/2022"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Always `"progress"` |
| `folders_scanned` | int | Folders walked so far |
| `current_path` | string | Relative path currently being scanned |

Flutter uses `folders_scanned` to animate a progress indicator. `current_path` is optional to display.

---

## 2. Findings Payload (Rust → Flutter)

Emitted once after full analysis is complete.

```json
{
  "type": "findings",
  "selected_folder": "/Users/karl/Documents",
  "scanned_at": "2026-03-28T14:32:00Z",
  "total_folders": 312,
  "findings": [
    {
      "id": "f1",
      "finding_type": "empty_folder",
      "severity": "issue",
      "path": "Old Projects/Archive",
      "absolute_path": "/Users/karl/Documents/Old Projects/Archive",
      "display_name": "Archive",
      "action": "remove",
      "destination": null,
      "absolute_destination": null,
      "inference_basis": "Folder contains no files",
      "triggered_by": null
    },
    {
      "id": "f2",
      "finding_type": "naming_inconsistency",
      "severity": "issue",
      "path": "Media/photoArchive",
      "absolute_path": "/Users/karl/Documents/Media/photoArchive",
      "display_name": "photoArchive",
      "action": "rename",
      "destination": "Media/Photo Archive",
      "absolute_destination": "/Users/karl/Documents/Media/Photo Archive",
      "inference_basis": "Title Case used by 94% of sibling folders",
      "triggered_by": null
    },
    {
      "id": "f3",
      "finding_type": "misplaced_file",
      "severity": "warning",
      "path": "Finance/invoice_2023.pdf",
      "absolute_path": "/Users/karl/Documents/Finance/invoice_2023.pdf",
      "display_name": "invoice_2023.pdf",
      "action": "move",
      "destination": "Finance/Invoices/invoice_2023.pdf",
      "absolute_destination": "/Users/karl/Documents/Finance/Invoices/invoice_2023.pdf",
      "inference_basis": ".pdf files appear in Finance/Invoices/ in 8 of 9 cases",
      "triggered_by": null
    },
    {
      "id": "f4",
      "finding_type": "excessive_nesting",
      "severity": "warning",
      "path": "Work/Projects/2022/Q3/Reports/Attachments",
      "absolute_path": "/Users/karl/Documents/Work/Projects/2022/Q3/Reports/Attachments",
      "display_name": "Attachments",
      "action": "move",
      "destination": "Work/Projects/2022/Attachments",
      "absolute_destination": "/Users/karl/Documents/Work/Projects/2022/Attachments",
      "inference_basis": "Folder depth is 6; threshold is 5",
      "triggered_by": null
    },
    {
      "id": "f5",
      "finding_type": "empty_folder",
      "severity": "issue",
      "path": "Old Projects",
      "absolute_path": "/Users/karl/Documents/Old Projects",
      "display_name": "Old Projects",
      "action": "remove",
      "destination": null,
      "absolute_destination": null,
      "inference_basis": "Will become empty if Archive (f1) is removed",
      "triggered_by": "f1"
    }
  ],
  "errors": []
}
```

### Finding fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique finding ID within this session |
| `finding_type` | enum | `empty_folder` \| `naming_inconsistency` \| `misplaced_file` \| `excessive_nesting` |
| `severity` | enum | `issue` \| `warning` |
| `path` | string | Relative path from selected folder |
| `absolute_path` | string | Full filesystem path — used for execution |
| `display_name` | string | Folder or file name only — used for display |
| `action` | enum | `remove` \| `rename` \| `move` |
| `destination` | string? | Proposed destination, relative. `null` for `remove` |
| `absolute_destination` | string? | Proposed destination, absolute. `null` for `remove` |
| `inference_basis` | string | Human-readable explanation for the **(why?)** affordance |
| `triggered_by` | string? | ID of the finding that caused this cascade. `null` if not a dependent |

### Envelope fields

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Always `"findings"` |
| `selected_folder` | string | Absolute path of the scanned folder |
| `scanned_at` | string | ISO 8601 timestamp |
| `total_folders` | int | Total folders walked |
| `findings` | array | Array of finding objects |
| `errors` | array | Any non-fatal errors encountered during scan (e.g. permission denied) |

### Error object

```json
{
  "path": "/Users/karl/Documents/SomeFolder",
  "message": "Permission denied"
}
```

---

## 3. Execution Plan (Flutter → Rust)

Sent via stdin after the user has approved findings and confirmed Preview Changes. Contains user overrides for any destinations the user changed.

```json
{
  "type": "execute",
  "selected_folder": "/Users/karl/Documents",
  "session_id": "2026-03-28T14-32-00",
  "actions": [
    {
      "finding_id": "f1",
      "action": "remove",
      "absolute_path": "/Users/karl/Documents/Old Projects/Archive"
    },
    {
      "finding_id": "f2",
      "action": "rename",
      "absolute_path": "/Users/karl/Documents/Media/photoArchive",
      "absolute_destination": "/Users/karl/Documents/Media/Photo Archive"
    },
    {
      "finding_id": "f3",
      "action": "move",
      "absolute_path": "/Users/karl/Documents/Finance/invoice_2023.pdf",
      "absolute_destination": "/Users/karl/Documents/Finance/Invoices/invoice_2023.pdf"
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Always `"execute"` |
| `selected_folder` | string | Absolute path of the scanned folder |
| `session_id` | string | Timestamp string used to name the quarantine folder and log file |
| `actions` | array | Approved actions, with user-overridden destinations where applicable |

**Note:** `absolute_destination` in the execution plan reflects the user's final choice — it may differ from the `absolute_destination` in the findings payload if the user chose an alternate location.

---

## 4. Execution Result (Rust → Flutter)

Emitted to stdout after all actions are complete.

```json
{
  "type": "execution_result",
  "session_id": "2026-03-28T14-32-00",
  "total": 3,
  "succeeded": 2,
  "skipped": 0,
  "failed": 1,
  "log_path": "/Users/karl/.filesteward/logs/2026-03-28T14-32-00.json",
  "quarantine_path": "/Users/karl/.filesteward/quarantine/2026-03-28T14-32-00",
  "entries": [
    {
      "finding_id": "f1",
      "action": "remove",
      "absolute_path": "/Users/karl/Documents/Old Projects/Archive",
      "absolute_destination": "/Users/karl/.filesteward/quarantine/2026-03-28T14-32-00/Old Projects/Archive",
      "outcome": "succeeded",
      "error": null
    },
    {
      "finding_id": "f2",
      "action": "rename",
      "absolute_path": "/Users/karl/Documents/Media/photoArchive",
      "absolute_destination": "/Users/karl/Documents/Media/Photo Archive",
      "outcome": "succeeded",
      "error": null
    },
    {
      "finding_id": "f3",
      "action": "move",
      "absolute_path": "/Users/karl/Documents/Finance/invoice_2023.pdf",
      "absolute_destination": "/Users/karl/Documents/Finance/Invoices/invoice_2023.pdf",
      "outcome": "failed",
      "error": "Destination already exists"
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Always `"execution_result"` |
| `session_id` | string | Matches the session_id from the execution plan |
| `total` | int | Total actions attempted |
| `succeeded` | int | Actions completed successfully |
| `skipped` | int | Actions skipped (e.g. user dismissed before execution) |
| `failed` | int | Actions that encountered an error |
| `log_path` | string | Absolute path to the session log file |
| `quarantine_path` | string | Absolute path to the session quarantine folder |
| `entries` | array | Per-action results |

### Entry outcome values

| Value | Meaning |
|-------|---------|
| `succeeded` | Action completed |
| `skipped` | Action was not attempted |
| `failed` | Action attempted but errored — see `error` field |

---

## Re-scan

After execution, Flutter triggers a re-scan of affected folders by invoking the Rust binary again with the same command but scoped paths. The re-scan produces progress messages (type: `"progress"`) and a findings payload (type: `"findings"`) using the same shapes as above. An empty findings array indicates no new issues.

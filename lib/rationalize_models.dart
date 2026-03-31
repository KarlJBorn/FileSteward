// Data models for Iteration 3 — Directory Rationalization.
// These types mirror the JSON contract defined in
// docs/json-contract-iteration-3.md exactly. Field names use camelCase
// Dart conventions; JSON key names match the Rust snake_case contract.

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

enum FindingType {
  emptyFolder,
  namingInconsistency,
  misplacedFile,
  excessiveNesting;

  static FindingType fromJson(String value) {
    switch (value) {
      case 'empty_folder':
        return FindingType.emptyFolder;
      case 'naming_inconsistency':
        return FindingType.namingInconsistency;
      case 'misplaced_file':
        return FindingType.misplacedFile;
      case 'excessive_nesting':
        return FindingType.excessiveNesting;
      default:
        return FindingType.emptyFolder;
    }
  }

  String get label {
    switch (this) {
      case FindingType.emptyFolder:
        return 'Empty folder';
      case FindingType.namingInconsistency:
        return 'Naming inconsistency';
      case FindingType.misplacedFile:
        return 'Misplaced file';
      case FindingType.excessiveNesting:
        return 'Excessive nesting';
    }
  }
}

enum FindingSeverity {
  issue,
  warning;

  static FindingSeverity fromJson(String value) {
    switch (value) {
      case 'issue':
        return FindingSeverity.issue;
      case 'warning':
        return FindingSeverity.warning;
      default:
        return FindingSeverity.issue;
    }
  }
}

enum FindingAction {
  remove,
  rename,
  move;

  static FindingAction fromJson(String value) {
    switch (value) {
      case 'remove':
        return FindingAction.remove;
      case 'rename':
        return FindingAction.rename;
      case 'move':
        return FindingAction.move;
      default:
        return FindingAction.remove;
    }
  }

  String toJson() => name;
}

// ---------------------------------------------------------------------------
// F1 — Finding
// ---------------------------------------------------------------------------

class RationalizeFinding {
  final String id;
  final FindingType findingType;
  final FindingSeverity severity;
  final String path;
  final String absolutePath;
  final String displayName;
  final FindingAction action;

  /// Proposed destination, relative. Null for remove actions.
  final String? destination;

  /// Proposed destination, absolute. Null for remove actions.
  final String? absoluteDestination;

  /// Human-readable explanation shown in the (why?) affordance.
  final String inferenceBasis;

  /// ID of the finding that caused this cascade. Null if not a dependent.
  final String? triggeredBy;

  const RationalizeFinding({
    required this.id,
    required this.findingType,
    required this.severity,
    required this.path,
    required this.absolutePath,
    required this.displayName,
    required this.action,
    this.destination,
    this.absoluteDestination,
    this.inferenceBasis = '',
    this.triggeredBy,
  });

  bool get isDependent => triggeredBy != null;

  /// True if this finding applies to a directory (not a file).
  bool get isFolder => findingType != FindingType.misplacedFile;

  factory RationalizeFinding.fromJson(Map<String, dynamic> json) {
    return RationalizeFinding(
      id: json['id'] as String? ?? '',
      findingType: FindingType.fromJson(json['finding_type'] as String? ?? ''),
      severity:
          FindingSeverity.fromJson(json['severity'] as String? ?? 'issue'),
      path: json['path'] as String? ?? '',
      absolutePath: json['absolute_path'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      action: FindingAction.fromJson(json['action'] as String? ?? 'remove'),
      destination: json['destination'] as String?,
      absoluteDestination: json['absolute_destination'] as String?,
      inferenceBasis: json['inference_basis'] as String? ?? '',
      triggeredBy: json['triggered_by'] as String?,
    );
  }
}

// ---------------------------------------------------------------------------
// F1 — FindingsPayload (Rust → Flutter, message type: "findings")
// ---------------------------------------------------------------------------

class ScanErrorEntry {
  final String path;
  final String message;

  const ScanErrorEntry({required this.path, required this.message});

  factory ScanErrorEntry.fromJson(Map<String, dynamic> json) {
    return ScanErrorEntry(
      path: json['path'] as String? ?? '',
      message: json['message'] as String? ?? '',
    );
  }
}

class FindingsPayload {
  final String selectedFolder;
  final String scannedAt;
  final int totalFolders;
  final List<RationalizeFinding> findings;
  final List<ScanErrorEntry> errors;

  const FindingsPayload({
    required this.selectedFolder,
    required this.scannedAt,
    required this.totalFolders,
    required this.findings,
    required this.errors,
  });

  factory FindingsPayload.fromJson(Map<String, dynamic> json) {
    final rawFindings = json['findings'] as List<dynamic>? ?? [];
    final rawErrors = json['errors'] as List<dynamic>? ?? [];
    return FindingsPayload(
      selectedFolder: json['selected_folder'] as String? ?? '',
      scannedAt: json['scanned_at'] as String? ?? '',
      totalFolders: json['total_folders'] as int? ?? 0,
      findings: rawFindings
          .map((e) =>
              RationalizeFinding.fromJson(e as Map<String, dynamic>))
          .toList(),
      errors: rawErrors
          .map((e) => ScanErrorEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Findings grouped by [FindingType] for display in the findings list.
  Map<FindingType, List<RationalizeFinding>> get byType {
    final result = <FindingType, List<RationalizeFinding>>{};
    for (final finding in findings) {
      result.putIfAbsent(finding.findingType, () => []).add(finding);
    }
    return result;
  }

  /// Look up a finding by its ID.
  RationalizeFinding? findById(String id) {
    for (final f in findings) {
      if (f.id == id) return f;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// F1 — ExecutionPlan (Flutter → Rust, message type: "execute")
// ---------------------------------------------------------------------------

class ExecutionActionItem {
  final String findingId;
  final FindingAction action;
  final String absolutePath;

  /// User-overridden or default destination. Null for remove actions.
  final String? absoluteDestination;

  const ExecutionActionItem({
    required this.findingId,
    required this.action,
    required this.absolutePath,
    this.absoluteDestination,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'finding_id': findingId,
      'action': action.toJson(),
      'absolute_path': absolutePath,
      if (absoluteDestination != null)
        'absolute_destination': absoluteDestination,
    };
  }
}

class ExecutionPlan {
  final String selectedFolder;
  final String sessionId;
  final List<ExecutionActionItem> actions;

  const ExecutionPlan({
    required this.selectedFolder,
    required this.sessionId,
    required this.actions,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'execute',
      'selected_folder': selectedFolder,
      'session_id': sessionId,
      'actions': actions.map((a) => a.toJson()).toList(),
    };
  }
}

// ---------------------------------------------------------------------------
// F1 — ExecutionResult (Rust → Flutter, message type: "execution_result")
// ---------------------------------------------------------------------------

enum ExecutionOutcome {
  succeeded,
  skipped,
  failed;

  static ExecutionOutcome fromJson(String value) {
    switch (value) {
      case 'succeeded':
        return ExecutionOutcome.succeeded;
      case 'skipped':
        return ExecutionOutcome.skipped;
      case 'failed':
        return ExecutionOutcome.failed;
      default:
        return ExecutionOutcome.failed;
    }
  }
}

class ExecutionEntryResult {
  final String findingId;
  final FindingAction action;
  final String absolutePath;
  final String absoluteDestination;
  final ExecutionOutcome outcome;
  final String? error;

  const ExecutionEntryResult({
    required this.findingId,
    required this.action,
    required this.absolutePath,
    required this.absoluteDestination,
    required this.outcome,
    this.error,
  });

  factory ExecutionEntryResult.fromJson(Map<String, dynamic> json) {
    return ExecutionEntryResult(
      findingId: json['finding_id'] as String? ?? '',
      action: FindingAction.fromJson(json['action'] as String? ?? 'remove'),
      absolutePath: json['absolute_path'] as String? ?? '',
      absoluteDestination: json['absolute_destination'] as String? ?? '',
      outcome: ExecutionOutcome.fromJson(
          json['outcome'] as String? ?? 'failed'),
      error: json['error'] as String?,
    );
  }
}

class ExecutionResult {
  final String sessionId;
  final int total;
  final int succeeded;
  final int skipped;
  final int failed;
  final String logPath;
  final String quarantinePath;
  final List<ExecutionEntryResult> entries;

  const ExecutionResult({
    required this.sessionId,
    required this.total,
    required this.succeeded,
    required this.skipped,
    required this.failed,
    required this.logPath,
    required this.quarantinePath,
    required this.entries,
  });

  factory ExecutionResult.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'] as List<dynamic>? ?? [];
    return ExecutionResult(
      sessionId: json['session_id'] as String? ?? '',
      total: json['total'] as int? ?? 0,
      succeeded: json['succeeded'] as int? ?? 0,
      skipped: json['skipped'] as int? ?? 0,
      failed: json['failed'] as int? ?? 0,
      logPath: json['log_path'] as String? ?? '',
      quarantinePath: json['quarantine_path'] as String? ?? '',
      entries: rawEntries
          .map((e) =>
              ExecutionEntryResult.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// BuildCommand (Flutter → Rust, message type: "build")
// ---------------------------------------------------------------------------

class BuildCommand {
  final String sourcePath;
  final String targetPath;
  final String sessionId;
  final List<ExecutionActionItem> actions;

  const BuildCommand({
    required this.sourcePath,
    required this.targetPath,
    required this.sessionId,
    required this.actions,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'build',
      'source_path': sourcePath,
      'target_path': targetPath,
      'session_id': sessionId,
      'actions': actions.map((a) => a.toJson()).toList(),
    };
  }
}

// ---------------------------------------------------------------------------
// BuildResult (Rust → Flutter, message type: "build_complete")
// ---------------------------------------------------------------------------

class BuildResult {
  final String sessionId;
  final String targetPath;
  final int foldersCopied;
  final int filesCopied;
  final int foldersOmitted;
  final String? error;

  const BuildResult({
    required this.sessionId,
    required this.targetPath,
    required this.foldersCopied,
    required this.filesCopied,
    required this.foldersOmitted,
    this.error,
  });

  bool get succeeded => error == null;

  factory BuildResult.fromJson(Map<String, dynamic> json) {
    return BuildResult(
      sessionId: json['session_id'] as String? ?? '',
      targetPath: json['target_path'] as String? ?? '',
      foldersCopied: json['folders_copied'] as int? ?? 0,
      filesCopied: json['files_copied'] as int? ?? 0,
      foldersOmitted: json['folders_omitted'] as int? ?? 0,
      error: json['error'] as String?,
    );
  }
}

// ---------------------------------------------------------------------------
// SwapCommand (Flutter → Rust, message type: "swap")
// ---------------------------------------------------------------------------

class SwapCommand {
  final String sourcePath;
  final String targetPath;

  const SwapCommand({
    required this.sourcePath,
    required this.targetPath,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'swap',
      'source_path': sourcePath,
      'target_path': targetPath,
    };
  }
}

// ---------------------------------------------------------------------------
// SwapResult (Rust → Flutter, message type: "swap_complete")
// ---------------------------------------------------------------------------

class SwapResult {
  final String oldPath;
  final String newPath;
  final String? error;

  const SwapResult({
    required this.oldPath,
    required this.newPath,
    this.error,
  });

  bool get succeeded => error == null;

  factory SwapResult.fromJson(Map<String, dynamic> json) {
    return SwapResult(
      oldPath: json['old_path'] as String? ?? '',
      newPath: json['new_path'] as String? ?? '',
      error: json['error'] as String?,
    );
  }
}

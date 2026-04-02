// Models for the Consolidate engine IPC layer.
//
// Rust emits NDJSON events to stdout; this file defines the Dart
// counterparts for each event type and the commands written to stdin.

// ---------------------------------------------------------------------------
// Inbound events (Rust → Dart)
// ---------------------------------------------------------------------------

sealed class ConsolidateEvent {}

class ConsolidateProgress extends ConsolidateEvent {
  final String source;
  final int filesScanned;

  ConsolidateProgress({required this.source, required this.filesScanned});

  factory ConsolidateProgress.fromJson(Map<String, dynamic> json) =>
      ConsolidateProgress(
        source: json['source'] as String,
        filesScanned: json['files_scanned'] as int,
      );
}

class UniqueFile {
  final String relativePath;
  final int sizeBytes;

  UniqueFile({required this.relativePath, required this.sizeBytes});

  factory UniqueFile.fromJson(Map<String, dynamic> json) => UniqueFile(
        relativePath: json['relative_path'] as String,
        sizeBytes: (json['size_bytes'] as num).toInt(),
      );
}

class SecondaryDiff {
  final String path;
  final List<UniqueFile> uniqueFiles;

  SecondaryDiff({required this.path, required this.uniqueFiles});

  factory SecondaryDiff.fromJson(Map<String, dynamic> json) => SecondaryDiff(
        path: json['path'] as String,
        uniqueFiles: (json['unique_files'] as List<dynamic>)
            .map((e) => UniqueFile.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ConsolidateScanComplete extends ConsolidateEvent {
  final String sessionId;
  final String primary;
  final List<SecondaryDiff> secondaries;

  ConsolidateScanComplete({
    required this.sessionId,
    required this.primary,
    required this.secondaries,
  });

  factory ConsolidateScanComplete.fromJson(Map<String, dynamic> json) =>
      ConsolidateScanComplete(
        sessionId: json['session_id'] as String,
        primary: json['primary'] as String,
        secondaries: (json['secondaries'] as List<dynamic>)
            .map((e) => SecondaryDiff.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ConsolidateBuildComplete extends ConsolidateEvent {
  final String sessionId;
  final String target;
  final int filesCopied;

  ConsolidateBuildComplete({
    required this.sessionId,
    required this.target,
    required this.filesCopied,
  });

  factory ConsolidateBuildComplete.fromJson(Map<String, dynamic> json) =>
      ConsolidateBuildComplete(
        sessionId: json['session_id'] as String,
        target: json['target'] as String,
        filesCopied: json['files_copied'] as int,
      );
}

class ConsolidateFinalizeComplete extends ConsolidateEvent {
  final String sessionId;

  ConsolidateFinalizeComplete({required this.sessionId});

  factory ConsolidateFinalizeComplete.fromJson(Map<String, dynamic> json) =>
      ConsolidateFinalizeComplete(sessionId: json['session_id'] as String);
}

class ConsolidateError extends ConsolidateEvent {
  final String message;

  ConsolidateError({required this.message});

  factory ConsolidateError.fromJson(Map<String, dynamic> json) =>
      ConsolidateError(message: json['message'] as String);
}

ConsolidateEvent? parseConsolidateEvent(Map<String, dynamic> json) {
  final type = json['type'] as String?;
  return switch (type) {
    'consolidate_progress' => ConsolidateProgress.fromJson(json),
    'consolidate_scan_complete' => ConsolidateScanComplete.fromJson(json),
    'consolidate_build_complete' => ConsolidateBuildComplete.fromJson(json),
    'consolidate_finalize_complete' =>
      ConsolidateFinalizeComplete.fromJson(json),
    'consolidate_error' => ConsolidateError.fromJson(json),
    _ => null,
  };
}

// ---------------------------------------------------------------------------
// Outbound commands (Dart → Rust stdin)
// ---------------------------------------------------------------------------

class FoldInCmd {
  final String sourceRoot;
  final String relativePath;

  FoldInCmd({required this.sourceRoot, required this.relativePath});

  Map<String, dynamic> toJson() => {
        'source_root': sourceRoot,
        'relative_path': relativePath,
      };
}

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

class ConsolidateLoadNotFound extends ConsolidateEvent {
  ConsolidateLoadNotFound();
}

// ---------------------------------------------------------------------------
// v2 event types
// ---------------------------------------------------------------------------

class ConsolidateDuplicateGroup {
  final List<String> paths;
  final String suggestedKeep;
  final List<String> reasons;
  final bool ambiguous;
  final int sizeBytes;

  ConsolidateDuplicateGroup({
    required this.paths,
    required this.suggestedKeep,
    required this.reasons,
    required this.ambiguous,
    required this.sizeBytes,
  });

  factory ConsolidateDuplicateGroup.fromJson(Map<String, dynamic> json) =>
      ConsolidateDuplicateGroup(
        paths: (json['paths'] as List<dynamic>).cast<String>(),
        suggestedKeep: json['suggested_keep'] as String,
        reasons: (json['reasons'] as List<dynamic>).cast<String>(),
        ambiguous: json['ambiguous'] as bool,
        sizeBytes: (json['size_bytes'] as num).toInt(),
      );
}

class ConsolidateRationalizeScanComplete extends ConsolidateEvent {
  final String sessionId;
  final String folder;
  final List<ConsolidateDuplicateGroup> duplicateGroups;
  final List<UniqueFile> cleanFiles;
  final int systemFilesSkipped;

  ConsolidateRationalizeScanComplete({
    required this.sessionId,
    required this.folder,
    required this.duplicateGroups,
    required this.cleanFiles,
    required this.systemFilesSkipped,
  });

  factory ConsolidateRationalizeScanComplete.fromJson(
          Map<String, dynamic> json) =>
      ConsolidateRationalizeScanComplete(
        sessionId: json['session_id'] as String,
        folder: json['folder'] as String,
        duplicateGroups: (json['duplicate_groups'] as List<dynamic>)
            .map((e) => ConsolidateDuplicateGroup.fromJson(
                e as Map<String, dynamic>))
            .toList(),
        cleanFiles: (json['clean_files'] as List<dynamic>)
            .map((e) => UniqueFile.fromJson(e as Map<String, dynamic>))
            .toList(),
        systemFilesSkipped: (json['system_files_skipped'] as num).toInt(),
      );
}

class ConsolidateFoldScanComplete extends ConsolidateEvent {
  final String sessionId;
  final String folder;
  final List<UniqueFile> uniqueFiles;

  ConsolidateFoldScanComplete({
    required this.sessionId,
    required this.folder,
    required this.uniqueFiles,
  });

  factory ConsolidateFoldScanComplete.fromJson(Map<String, dynamic> json) =>
      ConsolidateFoldScanComplete(
        sessionId: json['session_id'] as String,
        folder: json['folder'] as String,
        uniqueFiles: (json['unique_files'] as List<dynamic>)
            .map((e) => UniqueFile.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ConsolidateAccumulateComplete extends ConsolidateEvent {
  final String sessionId;
  final int accumulatedCount;

  ConsolidateAccumulateComplete({
    required this.sessionId,
    required this.accumulatedCount,
  });

  factory ConsolidateAccumulateComplete.fromJson(Map<String, dynamic> json) =>
      ConsolidateAccumulateComplete(
        sessionId: json['session_id'] as String,
        accumulatedCount: (json['accumulated_count'] as num).toInt(),
      );
}

// ---------------------------------------------------------------------------
// v3 event types (two-scan model)
// ---------------------------------------------------------------------------

class FolderGroup {
  final String relativePath;
  final List<int> sourceIndices;
  final int fileCount;
  final int totalSizeBytes;

  FolderGroup({
    required this.relativePath,
    required this.sourceIndices,
    required this.fileCount,
    required this.totalSizeBytes,
  });

  factory FolderGroup.fromJson(Map<String, dynamic> json) => FolderGroup(
        relativePath: json['relative_path'] as String,
        sourceIndices: (json['source_indices'] as List<dynamic>).cast<int>(),
        fileCount: (json['file_count'] as num).toInt(),
        totalSizeBytes: (json['total_size_bytes'] as num).toInt(),
      );
}

class FileTypeCount {
  final String extension;
  final int count;

  FileTypeCount({required this.extension, required this.count});

  factory FileTypeCount.fromJson(Map<String, dynamic> json) => FileTypeCount(
        extension: json['extension'] as String,
        count: (json['count'] as num).toInt(),
      );
}

class StructureScanComplete extends ConsolidateEvent {
  final List<String> sourceFolders;
  final List<FolderGroup> folderGroups;
  final List<FileTypeCount> fileTypeCounts;
  final int totalFiles;

  StructureScanComplete({
    required this.sourceFolders,
    required this.folderGroups,
    required this.fileTypeCounts,
    required this.totalFiles,
  });

  factory StructureScanComplete.fromJson(Map<String, dynamic> json) =>
      StructureScanComplete(
        sourceFolders: (json['source_folders'] as List<dynamic>).cast<String>(),
        folderGroups: (json['folder_groups'] as List<dynamic>)
            .map((e) => FolderGroup.fromJson(e as Map<String, dynamic>))
            .toList(),
        fileTypeCounts: (json['file_type_counts'] as List<dynamic>)
            .map((e) => FileTypeCount.fromJson(e as Map<String, dynamic>))
            .toList(),
        totalFiles: (json['total_files'] as num).toInt(),
      );
}

class RoutedFile {
  final String sourceFolder;
  final String sourceRelativePath;
  final String targetRelativePath;
  final String hash;
  final int sizeBytes;
  /// "copy" | "skip_duplicate" | "copy_renamed"
  final String action;
  final String? originalTargetPath;
  final String? duplicateOf;

  RoutedFile({
    required this.sourceFolder,
    required this.sourceRelativePath,
    required this.targetRelativePath,
    required this.hash,
    required this.sizeBytes,
    required this.action,
    this.originalTargetPath,
    this.duplicateOf,
  });

  factory RoutedFile.fromJson(Map<String, dynamic> json) => RoutedFile(
        sourceFolder: json['source_folder'] as String,
        sourceRelativePath: json['source_relative_path'] as String,
        targetRelativePath: json['target_relative_path'] as String,
        hash: json['hash'] as String,
        sizeBytes: (json['size_bytes'] as num).toInt(),
        action: json['action'] as String,
        originalTargetPath: json['original_target_path'] as String?,
        duplicateOf: json['duplicate_of'] as String?,
      );
}

class CollisionEntry {
  final String sourceFolder;
  final String sourceRelativePath;
  final String hash;
  final String renamedTo;

  CollisionEntry({
    required this.sourceFolder,
    required this.sourceRelativePath,
    required this.hash,
    required this.renamedTo,
  });

  factory CollisionEntry.fromJson(Map<String, dynamic> json) => CollisionEntry(
        sourceFolder: json['source_folder'] as String,
        sourceRelativePath: json['source_relative_path'] as String,
        hash: json['hash'] as String,
        renamedTo: json['renamed_to'] as String,
      );
}

class FilenameCollision {
  final String targetRelativePath;
  final List<CollisionEntry> entries;

  FilenameCollision({required this.targetRelativePath, required this.entries});

  factory FilenameCollision.fromJson(Map<String, dynamic> json) =>
      FilenameCollision(
        targetRelativePath: json['target_relative_path'] as String,
        entries: (json['entries'] as List<dynamic>)
            .map((e) => CollisionEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ContentScanAmbiguity {
  final String ambiguityType;
  final String description;
  final List<String> files;

  ContentScanAmbiguity({
    required this.ambiguityType,
    required this.description,
    required this.files,
  });

  factory ContentScanAmbiguity.fromJson(Map<String, dynamic> json) =>
      ContentScanAmbiguity(
        ambiguityType: json['ambiguity_type'] as String,
        description: json['description'] as String,
        files: (json['files'] as List<dynamic>).cast<String>(),
      );
}

class ContentScanComplete extends ConsolidateEvent {
  final int filesToCopy;
  final int duplicatesSkipped;
  final int totalOutputSizeBytes;
  final List<FilenameCollision> collisions;
  final List<ContentScanAmbiguity> ambiguities;
  final List<RoutedFile> routing;

  ContentScanComplete({
    required this.filesToCopy,
    required this.duplicatesSkipped,
    required this.totalOutputSizeBytes,
    required this.collisions,
    required this.ambiguities,
    required this.routing,
  });

  factory ContentScanComplete.fromJson(Map<String, dynamic> json) =>
      ContentScanComplete(
        filesToCopy: (json['files_to_copy'] as num).toInt(),
        duplicatesSkipped: (json['duplicates_skipped'] as num).toInt(),
        totalOutputSizeBytes:
            (json['total_output_size_bytes'] as num).toInt(),
        collisions: (json['collisions'] as List<dynamic>)
            .map((e) => FilenameCollision.fromJson(e as Map<String, dynamic>))
            .toList(),
        ambiguities: (json['ambiguities'] as List<dynamic>)
            .map((e) =>
                ContentScanAmbiguity.fromJson(e as Map<String, dynamic>))
            .toList(),
        routing: (json['routing'] as List<dynamic>)
            .map((e) => RoutedFile.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

ConsolidateEvent? parseConsolidateEvent(Map<String, dynamic> json) {
  final type = json['type'] as String?;
  return switch (type) {
    'consolidate_progress' => ConsolidateProgress.fromJson(json),
    'consolidate_scan_complete' => ConsolidateScanComplete.fromJson(json),
    'consolidate_build_complete' => ConsolidateBuildComplete.fromJson(json),
    'consolidate_finalize_complete' =>
      ConsolidateFinalizeComplete.fromJson(json),
    'consolidate_load_not_found' => ConsolidateLoadNotFound(),
    'consolidate_error' => ConsolidateError.fromJson(json),
    'consolidate_rationalize_scan_complete' =>
      ConsolidateRationalizeScanComplete.fromJson(json),
    'consolidate_fold_scan_complete' =>
      ConsolidateFoldScanComplete.fromJson(json),
    'consolidate_accumulate_complete' =>
      ConsolidateAccumulateComplete.fromJson(json),
    'consolidate_structure_scan_complete' =>
      StructureScanComplete.fromJson(json),
    'consolidate_content_scan_complete' =>
      ContentScanComplete.fromJson(json),
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

class V2FolderBuildCmd {
  final String folder;
  final List<String> relativePaths;

  V2FolderBuildCmd({required this.folder, required this.relativePaths});

  Map<String, dynamic> toJson() => {
        'folder': folder,
        'relative_paths': relativePaths,
      };
}

// ---------------------------------------------------------------------------
// v3 commands
// ---------------------------------------------------------------------------

/// A single routing instruction for the v3 build step.
class V3RoutedFileCmd {
  final String sourceFolder;
  final String sourceRelativePath;
  final String targetRelativePath;

  V3RoutedFileCmd({
    required this.sourceFolder,
    required this.sourceRelativePath,
    required this.targetRelativePath,
  });

  Map<String, dynamic> toJson() => {
        'source_folder': sourceFolder,
        'source_relative_path': sourceRelativePath,
        'target_relative_path': targetRelativePath,
      };
}

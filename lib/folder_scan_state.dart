import 'manifest_models.dart';

/// Immutable state for one source folder in the multi-source scan workflow.
class FolderScanState {
  final String folderPath;
  final ManifestResult? result;

  /// Non-null while a scan is in progress; null when idle or complete.
  final double? scanProgress;
  final int filesScanned;
  final int totalFiles;
  final String? errorMessage;

  const FolderScanState({
    required this.folderPath,
    this.result,
    this.scanProgress,
    this.filesScanned = 0,
    this.totalFiles = 0,
    this.errorMessage,
  });

  bool get isScanning => scanProgress != null;
  bool get isComplete => result != null;
  bool get hasError => errorMessage != null;
  bool get isPending => !isScanning && !isComplete && !hasError;

  FolderScanState copyWith({
    ManifestResult? result,
    double? scanProgress,
    bool clearScanProgress = false,
    int? filesScanned,
    int? totalFiles,
    String? errorMessage,
    bool clearError = false,
  }) {
    return FolderScanState(
      folderPath: folderPath,
      result: result ?? this.result,
      scanProgress: clearScanProgress ? null : (scanProgress ?? this.scanProgress),
      filesScanned: filesScanned ?? this.filesScanned,
      totalFiles: totalFiles ?? this.totalFiles,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

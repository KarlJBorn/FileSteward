import 'manifest_models.dart';

/// Events emitted by [ManifestService.buildManifestStreaming].
sealed class ScanEvent {}

/// Emitted periodically as the Rust engine hashes files.
class ScanProgress extends ScanEvent {
  final int filesScanned;
  final int totalFiles;

  ScanProgress({required this.filesScanned, required this.totalFiles});

  /// 0.0–1.0 completion fraction, or 0.0 if total is unknown.
  double get fraction => totalFiles > 0 ? filesScanned / totalFiles : 0.0;
}

/// Emitted once when the scan completes successfully.
class ScanComplete extends ScanEvent {
  final ManifestResult result;

  ScanComplete(this.result);
}

/// Emitted if the Rust process fails or produces invalid output.
class ScanError extends ScanEvent {
  final String message;

  ScanError(this.message);
}

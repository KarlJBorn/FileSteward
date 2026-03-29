import 'rationalize_models.dart';

/// Events emitted by [RationalizeService.scan].
sealed class RationalizeEvent {}

/// Emitted periodically as the Rust engine walks the directory tree.
class RationalizeProgress extends RationalizeEvent {
  final int foldersScanned;
  final String currentPath;

  RationalizeProgress({
    required this.foldersScanned,
    required this.currentPath,
  });
}

/// Emitted once when the scan completes and findings are ready.
class RationalizeScanComplete extends RationalizeEvent {
  final FindingsPayload payload;

  RationalizeScanComplete(this.payload);
}

/// Emitted if the Rust process fails or produces invalid output.
class RationalizeError extends RationalizeEvent {
  final String message;

  RationalizeError(this.message);
}

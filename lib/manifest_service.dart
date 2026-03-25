import 'dart:convert';
import 'dart:io';

import 'manifest_models.dart';
import 'scan_events.dart';

typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);
typedef RustBinaryResolver = File? Function();

/// Injectable factory for streaming process runs. Returns a [Stream<String>]
/// of stdout lines so tests can inject pre-canned NDJSON without spawning a
/// real process.
typedef StreamingProcessRunner =
    Stream<String> Function(String executable, List<String> arguments);

class ManifestServiceException implements Exception {
  final String message;

  const ManifestServiceException(this.message);

  @override
  String toString() => message;
}

class ManifestService {
  const ManifestService({
    this.processRunner = Process.run,
    this.rustBinaryResolver,
    this.streamingProcessRunner,
  });

  final ProcessRunner processRunner;
  final RustBinaryResolver? rustBinaryResolver;

  /// Injectable streaming runner. When null the service spawns a real process.
  final StreamingProcessRunner? streamingProcessRunner;

  // ---------------------------------------------------------------------------
  // Batch (non-streaming) path — used by existing callers and tests.
  // ---------------------------------------------------------------------------

  Future<ManifestResult> buildManifest(String selectedFolderPath) async {
    final File? rustBinary = _resolveRustBinary();
    if (rustBinary == null) {
      throw const ManifestServiceException(
        'Rust binary not found.\n\nBuild it first with:\n'
        'cargo build --manifest-path rust_core/Cargo.toml',
      );
    }

    final processResult = await processRunner(rustBinary.path, <String>[
      selectedFolderPath,
    ]);

    final String stdoutText = processResult.stdout.toString().trim();
    final String stderrText = processResult.stderr.toString().trim();

    if (processResult.exitCode != 0) {
      throw ManifestServiceException('Rust failed.\n\n$stderrText');
    }

    try {
      final Map<String, dynamic> decodedJson =
          jsonDecode(stdoutText) as Map<String, dynamic>;
      return ManifestResult.fromJson(decodedJson);
    } on FormatException catch (error) {
      throw ManifestServiceException('Invalid JSON from Rust.\n\n$error');
    }
  }

  // ---------------------------------------------------------------------------
  // Streaming path — passes --stream-progress to Rust and emits ScanEvents.
  // ---------------------------------------------------------------------------

  /// Runs the Rust engine with progress streaming enabled.
  ///
  /// Yields [ScanProgress] events as files are hashed, followed by a single
  /// [ScanComplete] when the manifest is ready, or [ScanError] on failure.
  Stream<ScanEvent> buildManifestStreaming(String selectedFolderPath) async* {
    final File? rustBinary = _resolveRustBinary();
    if (rustBinary == null) {
      yield ScanError(
        'Rust binary not found.\n\nBuild it first with:\n'
        'cargo build --manifest-path rust_core/Cargo.toml',
      );
      return;
    }

    final Stream<String> lines;

    if (streamingProcessRunner != null) {
      // Injected runner — used in tests.
      lines = streamingProcessRunner!(
        rustBinary.path,
        <String>[selectedFolderPath, '--stream-progress'],
      );
    } else {
      // Real process — spawn and stream stdout line by line.
      final Process process;
      try {
        process = await Process.start(rustBinary.path, <String>[
          selectedFolderPath,
          '--stream-progress',
        ]);
      } catch (e) {
        yield ScanError('Failed to start Rust process: $e');
        return;
      }

      // Consume stderr so the process does not block on a full buffer.
      final stderrBuffer = StringBuffer();
      process.stderr
          .transform(utf8.decoder)
          .listen((chunk) => stderrBuffer.write(chunk));

      // Yield lines from stdout; check exit code after the stream closes.
      final stdoutLines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in stdoutLines) {
        if (line.trim().isEmpty) continue;
        final ScanEvent? event = _parseNdjsonLine(line);
        if (event != null) yield event;
      }

      final exitCode = await process.exitCode;
      if (exitCode != 0) {
        yield ScanError(
          'Rust failed (exit $exitCode).\n\n${stderrBuffer.toString().trim()}',
        );
      }
      return;
    }

    // Injected-runner path: iterate the provided stream directly.
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final ScanEvent? event = _parseNdjsonLine(line);
      if (event != null) yield event;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  ScanEvent? _parseNdjsonLine(String line) {
    try {
      final Map<String, dynamic> json =
          jsonDecode(line) as Map<String, dynamic>;
      final String type = json['type'] as String? ?? '';
      switch (type) {
        case 'counting_complete':
          return ScanProgress(
            filesScanned: 0,
            totalFiles: json['total_files'] as int? ?? 0,
          );
        case 'progress':
          return ScanProgress(
            filesScanned: json['files_scanned'] as int? ?? 0,
            totalFiles: json['total_files'] as int? ?? 0,
          );
        case 'result':
          return ScanComplete(ManifestResult.fromJson(json));
        default:
          return null; // Unknown event type — ignore gracefully.
      }
    } on FormatException {
      return null; // Malformed line — skip.
    }
  }

  File? _resolveRustBinary() {
    // If a resolver is explicitly injected (e.g. in tests), use it exclusively
    // and do not fall through to the default path search.
    if (rustBinaryResolver != null) {
      return rustBinaryResolver!();
    }

    final String? overridePath =
        Platform.environment['FILESTEWARD_RUST_BINARY'];
    final List<String> candidatePaths = <String>[
      if (overridePath != null && overridePath.isNotEmpty) overridePath,
      'rust_core/target/debug/rust_core',
      '../rust_core/target/debug/rust_core',
      '../../rust_core/target/debug/rust_core',
    ];

    for (final candidatePath in candidatePaths) {
      final file = File(candidatePath);
      if (file.existsSync()) {
        return file;
      }
    }

    return null;
  }
}

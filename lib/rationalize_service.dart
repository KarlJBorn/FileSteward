import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'rationalize_events.dart';
import 'rationalize_models.dart';

/// Manages the two-phase communication with the Rust rationalize engine:
///
///   Phase 1 — Scan: spawn process, stream progress events + findings payload.
///   Phase 2 — Execute: write execution plan to stdin, read execution result.
///
/// Usage:
/// ```dart
/// final session = await RationalizeService().startSession(folderPath);
/// await for (final event in session.events) { ... }
/// final result = await session.execute(plan);
/// await session.dispose();
/// ```
class RationalizeService {
  const RationalizeService({this.rustBinaryResolver});

  /// Optional override for locating the Rust binary (primarily for tests).
  final File? Function()? rustBinaryResolver;

  Future<RationalizeSession> startSession(String folderPath) async {
    final File? binary = _resolveRustBinary();
    if (binary == null) {
      return RationalizeSession._failed(
        'Rust binary not found.\n\nBuild it first with:\n'
        'cargo build --manifest-path rust_core/Cargo.toml',
      );
    }

    final Process process;
    try {
      process = await Process.start(binary.path, ['rationalize', folderPath]);
    } catch (e) {
      return RationalizeSession._failed('Failed to start Rust process: $e');
    }

    return RationalizeSession._started(process);
  }

  File? _resolveRustBinary() {
    if (rustBinaryResolver != null) return rustBinaryResolver!();

    final override = Platform.environment['FILESTEWARD_RUST_BINARY'];
    final candidates = <String>[
      if (override != null && override.isNotEmpty) override,
      'rust_core/target/debug/rust_core',
      '../rust_core/target/debug/rust_core',
      '../../rust_core/target/debug/rust_core',
    ];

    for (final path in candidates) {
      final f = File(path);
      if (f.existsSync()) return f;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// RationalizeSession — owns the live process and the two phases
// ---------------------------------------------------------------------------

class RationalizeSession {
  final Process? _process;
  final String? _startupError;

  // Stdout lines are consumed once via StreamIterator; both phases share it.
  final StreamIterator<String>? _stdout;

  FindingsPayload? _findings;

  /// Findings from the completed scan. Null until [events] stream completes.
  FindingsPayload? get findings => _findings;

  RationalizeSession._started(Process process)
      : _process = process,
        _startupError = null,
        _stdout = StreamIterator(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );

  RationalizeSession._failed(String error)
      : _process = null,
        _startupError = error,
        _stdout = null;

  // ---------------------------------------------------------------------------
  // Phase 1 — Scan
  // ---------------------------------------------------------------------------

  /// Stream of [RationalizeEvent]s produced during the scan phase.
  ///
  /// Yields [RationalizeProgress] events while the engine walks the tree,
  /// then a single [RationalizeScanComplete] when the findings payload arrives.
  /// Yields [RationalizeError] if the process fails to start or produces
  /// invalid output.
  ///
  /// After the stream closes, [findings] is populated and [execute] may be
  /// called.
  Stream<RationalizeEvent> get events async* {
    if (_startupError != null) {
      yield RationalizeError(_startupError);
      return;
    }

    final stdout = _stdout!;
    final process = _process!;

    // Consume stderr in the background so the process never blocks.
    final stderrBuf = StringBuffer();
    process.stderr
        .transform(utf8.decoder)
        .listen((chunk) => stderrBuf.write(chunk));

    while (await stdout.moveNext()) {
      final line = stdout.current.trim();
      if (line.isEmpty) continue;

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(line) as Map<String, dynamic>;
      } on FormatException {
        continue; // malformed line — skip
      }

      final type = json['type'] as String? ?? '';

      switch (type) {
        case 'progress':
          yield RationalizeProgress(
            foldersScanned: json['folders_scanned'] as int? ?? 0,
            currentPath: json['current_path'] as String? ?? '',
          );

        case 'findings':
          _findings = FindingsPayload.fromJson(json);
          yield RationalizeScanComplete(_findings!);
          return; // scan phase complete; stdout stays open for execute phase

        default:
          continue; // unknown event type — ignore gracefully
      }
    }

    // Stdout closed before we got a findings payload.
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      yield RationalizeError(
        'Rust failed (exit $exitCode).\n\n${stderrBuf.toString().trim()}',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Phase 2 — Execute
  // ---------------------------------------------------------------------------

  /// Send [plan] to Rust via stdin and wait for the execution result.
  ///
  /// Must only be called after the [events] stream has completed (i.e. after
  /// [RationalizeScanComplete] has been yielded).
  Future<ExecutionResult?> execute(ExecutionPlan plan) async {
    if (_process == null || _stdout == null) return null;

    // Write execution plan as a single JSON line to stdin, then close stdin
    // to signal end of input to the Rust process.
    final planJson = jsonEncode(plan.toJson());
    try {
      _process.stdin.writeln(planJson);
      await _process.stdin.flush();
      await _process.stdin.close();
    } catch (_) {
      return null;
    }

    // Read lines from stdout until we get the execution_result event.
    final stdout = _stdout;
    while (await stdout.moveNext()) {
      final line = stdout.current.trim();
      if (line.isEmpty) continue;

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(line) as Map<String, dynamic>;
      } on FormatException {
        continue;
      }

      if (json['type'] == 'execution_result') {
        return ExecutionResult.fromJson(json);
      }
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

  Future<void> dispose() async {
    await _stdout?.cancel();
    _process?.kill();
  }
}

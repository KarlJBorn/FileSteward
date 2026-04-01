import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'rationalize_events.dart';
import 'rationalize_models.dart';

/// Manages the three-phase communication with the Rust rationalize engine:
///
///   Phase 1 — Scan: spawn process, stream progress events + findings payload.
///   Phase 2 — Build: write BuildCommand to stdin, stream build_progress events,
///              receive build_complete.
///   Phase 3 — Swap: write SwapCommand to stdin, receive swap_complete.
///
/// Usage:
/// ```dart
/// final session = await RationalizeService().startSession(folderPath);
/// await for (final event in session.events) { ... }
/// final buildResult = await session.build(buildCommand, onProgress: ...);
/// final swapResult = await session.swap(swapCommand);
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
  // Phase 2 — Build
  // ---------------------------------------------------------------------------

  /// Send [cmd] to Rust and stream build progress until build_complete arrives.
  ///
  /// [onProgress] is called for each build_progress event (may be null).
  /// Returns [BuildResult] on completion (check [BuildResult.succeeded]).
  ///
  /// Must only be called after the [events] stream has completed.
  Future<BuildResult?> build(
    BuildCommand cmd, {
    void Function(int done, int total, String current)? onProgress,
  }) async {
    if (_process == null || _stdout == null) return null;

    final cmdJson = jsonEncode(cmd.toJson());
    try {
      _process.stdin.writeln(cmdJson);
      await _process.stdin.flush();
      // Do NOT close stdin — swap command follows.
    } catch (_) {
      return null;
    }

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

      switch (json['type'] as String? ?? '') {
        case 'build_progress':
          onProgress?.call(
            json['folders_done'] as int? ?? 0,
            json['folders_total'] as int? ?? 0,
            json['current'] as String? ?? '',
          );
        case 'build_complete':
          return BuildResult.fromJson(json);
      }
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // Phase 3 — Swap
  // ---------------------------------------------------------------------------

  /// Send [cmd] to Rust and wait for swap_complete.
  ///
  /// Must only be called after [build] has returned successfully.
  /// Closes stdin after writing so the Rust process can exit.
  Future<SwapResult?> swap(SwapCommand cmd) async {
    if (_process == null || _stdout == null) return null;

    final cmdJson = jsonEncode(cmd.toJson());
    try {
      _process.stdin.writeln(cmdJson);
      await _process.stdin.flush();
      await _process.stdin.close(); // no more commands after swap
    } catch (_) {
      return null;
    }

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

      if (json['type'] == 'swap_complete') {
        return SwapResult.fromJson(json);
      }
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // Phase 2 (legacy) — Execute (in-place; kept during transition)
  // ---------------------------------------------------------------------------

  /// Legacy in-place execution. Use [build] + [swap] for new code.
  Future<ExecutionResult?> execute(ExecutionPlan plan) async {
    if (_process == null || _stdout == null) return null;

    final planJson = jsonEncode(plan.toJson());
    try {
      _process.stdin.writeln(planJson);
      await _process.stdin.flush();
      await _process.stdin.close();
    } catch (_) {
      return null;
    }

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

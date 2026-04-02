import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'consolidate_models.dart';

/// Spawns the Rust binary in `consolidate` mode for a single command, streams
/// NDJSON events back, and closes the process.
///
/// Each public method creates a fresh process — the Rust handler reads one
/// command line from stdin and exits.
class ConsolidateService {
  const ConsolidateService({this.rustBinaryResolver});

  final File? Function()? rustBinaryResolver;

  // ---------------------------------------------------------------------------
  // Scan
  // ---------------------------------------------------------------------------

  /// Walk [primary] and each of [secondaries], yielding unique files per source.
  Stream<ConsolidateEvent> scan({
    required String primary,
    required List<String> secondaries,
  }) {
    final cmd = {
      'command': 'consolidate_scan',
      'primary': primary,
      'secondaries': secondaries,
    };
    return _run(cmd);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  /// Copy approved [foldIns] files into [target]. Yields progress + complete.
  Stream<ConsolidateEvent> build({
    required String sessionId,
    required String target,
    required List<FoldInCmd> foldIns,
  }) {
    final cmd = {
      'command': 'consolidate_build',
      'session_id': sessionId,
      'target': target,
      'fold_ins': foldIns.map((f) => f.toJson()).toList(),
    };
    return _run(cmd);
  }

  // ---------------------------------------------------------------------------
  // Finalize
  // ---------------------------------------------------------------------------

  /// Mark the session as finalized in the registry.
  Stream<ConsolidateEvent> finalize({required String sessionId}) {
    final cmd = {
      'command': 'consolidate_finalize',
      'session_id': sessionId,
    };
    return _run(cmd);
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Stream<ConsolidateEvent> _run(Map<String, dynamic> command) async* {
    final binary = _resolveRustBinary();
    if (binary == null) {
      yield ConsolidateError(
        message: 'Rust binary not found.\n\n'
            'Build it first with:\ncargo build --manifest-path rust_core/Cargo.toml',
      );
      return;
    }

    final Process process;
    try {
      process = await Process.start(binary.path, ['consolidate']);
    } catch (e) {
      yield ConsolidateError(message: 'Failed to start Rust process: $e');
      return;
    }

    // Write the command JSON to stdin and close.
    final commandJson = jsonEncode(command);
    process.stdin.writeln(commandJson);
    await process.stdin.close();

    // Stream stdout lines as events.
    await for (final line in process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final event = parseConsolidateEvent(json);
        if (event != null) yield event;
      } catch (_) {
        // Non-JSON line — ignore (e.g. debug output).
      }
    }

    await process.exitCode;
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

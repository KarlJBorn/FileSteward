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
  // Load (resume)
  // ---------------------------------------------------------------------------

  /// Check the registry for an existing scan matching [primary] + [secondaries].
  /// Emits [ConsolidateScanComplete] if found, [ConsolidateLoadNotFound] if not.
  Stream<ConsolidateEvent> load({
    required String primary,
    required List<String> secondaries,
  }) {
    final cmd = {
      'command': 'consolidate_load',
      'primary': primary,
      'secondaries': secondaries,
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
  // v2: Rationalize scan
  // ---------------------------------------------------------------------------

  /// Walk [folder] and find internal duplicates. Pass empty [sessionId] to
  /// create a new session; the response will contain the assigned ID.
  Stream<ConsolidateEvent> rationalizeScan({
    required String sessionId,
    required String folder,
  }) {
    final cmd = {
      'command': 'consolidate_rationalize_scan',
      'session_id': sessionId,
      'folder': folder,
    };
    return _run(cmd);
  }

  // ---------------------------------------------------------------------------
  // v2: Fold scan
  // ---------------------------------------------------------------------------

  /// Walk [folder] and find files not already in the session's accumulated
  /// hashes.
  Stream<ConsolidateEvent> foldScan({
    required String sessionId,
    required String folder,
  }) {
    final cmd = {
      'command': 'consolidate_fold_scan',
      'session_id': sessionId,
      'folder': folder,
    };
    return _run(cmd);
  }

  // ---------------------------------------------------------------------------
  // v2: Accumulate
  // ---------------------------------------------------------------------------

  /// Record [approvedHashes] into the session's accumulated set. Optionally
  /// update [folders] and [target].
  Stream<ConsolidateEvent> accumulate({
    required String sessionId,
    required List<String> approvedHashes,
    List<String> folders = const [],
    String target = '',
  }) {
    final cmd = {
      'command': 'consolidate_accumulate',
      'session_id': sessionId,
      'approved_hashes': approvedHashes,
      'folders': folders,
      'target': target,
    };
    return _run(cmd);
  }

  // ---------------------------------------------------------------------------
  // v2: Build
  // ---------------------------------------------------------------------------

  /// Copy files from each folder into [target] using [folders] approvals.
  Stream<ConsolidateEvent> v2Build({
    required String sessionId,
    required String target,
    required List<V2FolderBuildCmd> folders,
  }) {
    final cmd = {
      'command': 'consolidate_v2_build',
      'session_id': sessionId,
      'target': target,
      'folders': folders.map((f) => f.toJson()).toList(),
    };
    return _run(cmd);
  }

  // ---------------------------------------------------------------------------
  // v3: Structure scan (Scan 1 — no hashing)
  // ---------------------------------------------------------------------------

  /// Walk [folders], detect structurally equivalent subdirectories, count file
  /// types. No hashing — fast first pass for the Scan 1 UI.
  Stream<ConsolidateEvent> structureScan({
    required List<String> folders,
  }) {
    final cmd = {
      'command': 'consolidate_structure_scan',
      'folders': folders,
    };
    return _run(cmd);
  }

  // ---------------------------------------------------------------------------
  // v3: Content scan (Scan 2 — with hashing)
  // ---------------------------------------------------------------------------

  /// Hash all files in [folders], deduplicate by hash, route each file to its
  /// target, detect filename collisions (sequential rename) and ambiguities.
  Stream<ConsolidateEvent> contentScan({
    required List<String> folders,
    List<String> excludedExtensions = const [],
    List<String> excludedFolders = const [],
    List<String> overriddenPaths = const [],
  }) {
    final cmd = {
      'command': 'consolidate_content_scan',
      'folders': folders,
      'excluded_extensions': excludedExtensions,
      'excluded_folders': excludedFolders,
      'overridden_paths': overriddenPaths,
    };
    return _run(cmd);
  }

  // ---------------------------------------------------------------------------
  // v3: Build (content scan routing plan)
  // ---------------------------------------------------------------------------

  /// Execute a build from the v3 content scan routing plan.
  /// [routing] should be the resolved routing list with collision overrides
  /// already applied. Only "copy" and "copy_renamed" actions are sent.
  Stream<ConsolidateEvent> v3Build({
    required String target,
    required List<V3RoutedFileCmd> routing,
  }) {
    final cmd = {
      'command': 'consolidate_v3_build',
      'target': target,
      'routing': routing.map((r) => r.toJson()).toList(),
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
    // When running as a macOS .app bundle the executable lives at
    // Contents/MacOS/FileSteward; we also ship rust_core there.
    final bundleSibling =
        '${File(Platform.resolvedExecutable).parent.path}/rust_core';
    final candidates = <String>[
      if (override != null && override.isNotEmpty) override,
      bundleSibling,
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

/// Integration tests for RationalizeService — I3.
///
/// These tests spawn the real Rust binary against the test_corpus/rationalize
/// fixture and verify the findings payload matches expectations.
///
/// Prerequisites: `make rust-build` must have been run before running tests.
/// The FILESTEWARD_RUST_BINARY env var or the default binary path must resolve.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:filesteward/rationalize_models.dart';
import 'package:filesteward/rationalize_service.dart';
import 'package:filesteward/rationalize_events.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Locate the compiled Rust binary using the same resolution order as the
/// service itself.
File? _findRustBinary() {
  final override = Platform.environment['FILESTEWARD_RUST_BINARY'];
  final candidates = <String>[
    if (override != null && override.isNotEmpty) override,
    'rust_core/target/debug/rust_core',
    '../rust_core/target/debug/rust_core',
    '../../rust_core/target/debug/rust_core',
  ];
  for (final p in candidates) {
    final f = File(p);
    if (f.existsSync()) return f;
  }
  return null;
}

/// Locate the rationalize test corpus.
Directory? _findCorpus() {
  final candidates = [
    'test_corpus/rationalize',
    '../test_corpus/rationalize',
    '../../test_corpus/rationalize',
  ];
  for (final p in candidates) {
    final d = Directory(p);
    if (d.existsSync()) return d;
  }
  return null;
}

void main() {
  // ---------------------------------------------------------------------------
  // Unit-level: RationalizeSession mock (ndjson injection via fake binary)
  // ---------------------------------------------------------------------------

  group('RationalizeSession — injected stdout', () {
    test('events stream yields progress then scan_complete', () async {
      // Build a fake binary script that emits pre-canned NDJSON then waits
      // for stdin (execution plan) and emits a result.
      final script = await _writeFakeScript(
        scan: [
          '{"type":"progress","folders_scanned":1,"current_path":"Alpha"}',
          '{"type":"progress","folders_scanned":2,"current_path":"Beta"}',
          '{"type":"findings","selected_folder":"/tmp/test","scanned_at":"2026-01-01T00:00:00Z",'
              '"total_folders":2,"findings":[],"errors":[]}',
        ],
        execResult:
            '{"type":"execution_result","session_id":"test-session",'
            '"total":0,"succeeded":0,"skipped":0,"failed":0,'
            '"log_path":"/tmp/log.json","quarantine_path":"/tmp/q","entries":[]}',
      );
      if (script == null) {
        // Python3 not available — skip gracefully
        return;
      }

      try {
        final service = RationalizeService(rustBinaryResolver: () => script);
        final session = await service.startSession('/tmp/test');

        final events = <RationalizeEvent>[];
        await for (final e in session.events) {
          events.add(e);
        }

        expect(events.whereType<RationalizeProgress>(), hasLength(2));
        expect(events.whereType<RationalizeScanComplete>(), hasLength(1));

        final complete =
            events.whereType<RationalizeScanComplete>().first;
        expect(complete.payload.selectedFolder, '/tmp/test');
        expect(complete.payload.totalFolders, 2);
        expect(session.findings, isNotNull);

        // Execute with empty plan
        final plan = ExecutionPlan(
          selectedFolder: '/tmp/test',
          sessionId: 'test-session',
          actions: [],
        );
        final result = await session.execute(plan);
        expect(result, isNotNull);
        expect(result!.sessionId, 'test-session');
        expect(result.total, 0);

        await session.dispose();
      } finally {
        script.deleteSync();
      }
    });

    test('RationalizeError emitted when binary is missing', () async {
      final service = RationalizeService(rustBinaryResolver: () => null);
      final session = await service.startSession('/tmp/test');

      final events = await session.events.toList();
      expect(events, hasLength(1));
      expect(events.first, isA<RationalizeError>());
      expect(
        (events.first as RationalizeError).message,
        contains('Rust binary not found'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Integration: real Rust binary + test_corpus/rationalize
  // ---------------------------------------------------------------------------

  group('RationalizeService integration — test_corpus/rationalize', () {
    late File rustBinary;
    late Directory corpus;
    late bool isAvailable;

    setUpAll(() {
      final bin = _findRustBinary();
      final corp = _findCorpus();
      rustBinary = bin ?? File('__not_found__');
      corpus = corp ?? Directory('__not_found__');
      isAvailable = rustBinary.existsSync() && corpus.existsSync();
    });

    test('scan produces expected finding types', () async {
      if (!isAvailable) {
        // Binary or corpus not found — skip gracefully
        return;
      }

      final service =
          RationalizeService(rustBinaryResolver: () => rustBinary);
      final session = await service.startSession(corpus.path);

      FindingsPayload? payload;
      await for (final event in session.events) {
        if (event is RationalizeScanComplete) {
          payload = event.payload;
        }
      }
      // Send empty execution plan to let the process exit cleanly
      await session.execute(ExecutionPlan(
        selectedFolder: corpus.path,
        sessionId: 'test-${DateTime.now().millisecondsSinceEpoch}',
        actions: [],
      ));
      await session.dispose();

      expect(payload, isNotNull,
          reason: 'Expected a findings payload from the scan');
      final findings = payload!.findings;

      // ── empty_folder ────────────────────────────────────────────────────
      final emptyFindings = findings
          .where((f) => f.findingType == FindingType.emptyFolder)
          .toList();
      expect(emptyFindings, isNotEmpty,
          reason: 'Expected at least one empty_folder finding');

      final directEmpty =
          emptyFindings.where((f) => f.triggeredBy == null).toList();
      final cascadeEmpty =
          emptyFindings.where((f) => f.triggeredBy != null).toList();

      // Archive and Empty Folder are directly empty
      expect(
        directEmpty.map((f) => f.displayName),
        containsAll(<String>['Archive', 'Empty Folder']),
      );
      // Old Projects is a cascade
      expect(
        cascadeEmpty.map((f) => f.displayName),
        contains('Old Projects'),
      );
      // Cascade triggered_by references a real finding ID
      final cascade = cascadeEmpty.first;
      final triggering = payload.findById(cascade.triggeredBy!);
      expect(triggering, isNotNull,
          reason:
              'triggered_by "${cascade.triggeredBy}" should reference a real finding');

      // ── naming_inconsistency ─────────────────────────────────────────────
      final namingFindings = findings
          .where((f) => f.findingType == FindingType.namingInconsistency)
          .toList();
      expect(namingFindings, hasLength(1));
      expect(namingFindings.first.displayName, 'kappa_misc');
      expect(namingFindings.first.action, FindingAction.rename);
      expect(namingFindings.first.destination, isNotNull);
      // Rename should produce a Title Case version
      expect(
        namingFindings.first.destination,
        contains('Kappa Misc'),
      );

      // ── excessive_nesting ────────────────────────────────────────────────
      final nestingFindings = findings
          .where((f) => f.findingType == FindingType.excessiveNesting)
          .toList();
      expect(nestingFindings, hasLength(1));
      expect(nestingFindings.first.displayName, 'L6');
      expect(nestingFindings.first.action, FindingAction.move);
      expect(nestingFindings.first.inferenceBasis,
          contains('threshold is 5'));
    });

    test('execute plan moves to quarantine', () async {
      if (!isAvailable) return;

      // Create a throw-away temp folder with a single empty subfolder
      final tmp = Directory.systemTemp.createTempSync('rationalize_exec_');
      try {
        final toRemove = Directory('${tmp.path}/ToRemove')..createSync();

        final service =
            RationalizeService(rustBinaryResolver: () => rustBinary);
        final session = await service.startSession(tmp.path);

        FindingsPayload? payload;
        await for (final event in session.events) {
          if (event is RationalizeScanComplete) {
            payload = event.payload;
          }
        }
        expect(payload, isNotNull);

        // Find the empty_folder finding for ToRemove
        final finding = payload!.findings.firstWhere(
          (f) =>
              f.findingType == FindingType.emptyFolder &&
              f.displayName == 'ToRemove',
          orElse: () => throw StateError('Expected ToRemove finding'),
        );

        final sessionId =
            'test-${DateTime.now().millisecondsSinceEpoch}';
        final plan = ExecutionPlan(
          selectedFolder: tmp.path,
          sessionId: sessionId,
          actions: [
            ExecutionActionItem(
              findingId: finding.id,
              action: FindingAction.remove,
              absolutePath: finding.absolutePath,
            ),
          ],
        );

        final result = await session.execute(plan);
        await session.dispose();

        expect(result, isNotNull);
        expect(result!.succeeded, 1);
        expect(result.failed, 0);

        // ToRemove should no longer exist at its original location
        expect(toRemove.existsSync(), isFalse,
            reason: 'Folder should have been moved to quarantine');

        // Quarantine folder should exist
        final quarantineDir =
            Directory(result.quarantinePath);
        expect(quarantineDir.existsSync(), isTrue,
            reason:
                'Quarantine directory should have been created at ${result.quarantinePath}');

        // Log file should exist
        expect(File(result.logPath).existsSync(), isTrue,
            reason: 'Log file should have been written');

        // Cleanup quarantine entry (don't leave test artifacts)
        quarantineDir.deleteSync(recursive: true);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Fake binary helper
// ---------------------------------------------------------------------------

/// Write a Python3 script that emits [scan] lines to stdout, reads one line
/// from stdin (execution plan), then emits [execResult]. Returns null if
/// python3 is not available on this system.
Future<File?> _writeFakeScript({
  required List<String> scan,
  required String execResult,
}) async {
  // Check python3 available
  try {
    final check = await Process.run('python3', ['--version']);
    if (check.exitCode != 0) return null;
  } catch (_) {
    return null;
  }

  final tmp = File(
      '${Directory.systemTemp.path}/fake_rationalize_${DateTime.now().millisecondsSinceEpoch}.py');

  final scanLines = scan
      .map((l) => "sys.stdout.write(${jsonEncode(l)} + '\\n')\nsys.stdout.flush()")
      .join('\n');

  tmp.writeAsStringSync('''#!/usr/bin/env python3
import sys
$scanLines
sys.stdin.readline()
sys.stdout.write(${jsonEncode(execResult)} + '\\n')
sys.stdout.flush()
''');

  // Make executable
  await Process.run('chmod', ['+x', tmp.path]);
  return tmp;
}

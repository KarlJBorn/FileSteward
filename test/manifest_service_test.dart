import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:filesteward/manifest_service.dart';
import 'package:filesteward/scan_events.dart';

void main() {
  group('buildManifestStreaming', _streamingTests);

  test('buildManifest parses Rust JSON output', () async {
    const service = ManifestService(
      rustBinaryResolver: _fakeRustBinary,
      processRunner: _successfulProcessRun,
    );

    final result = await service.buildManifest('/tmp/example');

    expect(result.selectedFolder, '/tmp/example');
    expect(result.exists, isTrue);
    expect(result.isDirectory, isTrue);
    expect(result.totalDirectories, 1);
    expect(result.totalFiles, 1);
    expect(result.entries.map((entry) => entry.relativePath), <String>[
      'docs',
      'docs/readme.txt',
    ]);
    expect(result.entries.last.sha256, 'abc123');
    expect(result.duplicateGroups, isEmpty);
  });

  test('buildManifest parses duplicate_groups from Rust output', () async {
    const service = ManifestService(
      rustBinaryResolver: _fakeRustBinary,
      processRunner: _duplicatesProcessRun,
    );

    final result = await service.buildManifest('/tmp/example');

    expect(result.duplicateGroups, hasLength(1));
    expect(
      result.duplicateGroups.first,
      containsAll(<String>['a.txt', 'b.txt']),
    );
  });

  test('buildManifest surfaces Rust process failures', () async {
    const service = ManifestService(
      rustBinaryResolver: _fakeRustBinary,
      processRunner: _failingProcessRun,
    );

    await expectLater(
      service.buildManifest('/tmp/example'),
      throwsA(
        isA<ManifestServiceException>().having(
          (error) => error.message,
          'message',
          contains('permission denied'),
        ),
      ),
    );
  });
}

File _fakeRustBinary() => File('/tmp/fake-rust-core');

Future<ProcessResult> _successfulProcessRun(
  String executable,
  List<String> arguments,
) async {
  expect(executable, '/tmp/fake-rust-core');
  expect(arguments, <String>['/tmp/example']);

  return ProcessResult(1, 0, '''
{
  "selected_folder": "/tmp/example",
  "exists": true,
  "is_directory": true,
  "total_directories": 1,
  "total_files": 1,
  "duplicate_groups": [],
  "entries": [
    {
      "relative_path": "docs",
      "entry_type": "directory",
      "size_bytes": null,
      "sha256": null
    },
    {
      "relative_path": "docs/readme.txt",
      "entry_type": "file",
      "size_bytes": 512,
      "sha256": "abc123"
    }
  ]
}
''', '');
}

Future<ProcessResult> _duplicatesProcessRun(
  String executable,
  List<String> arguments,
) async {
  return ProcessResult(1, 0, '''
{
  "selected_folder": "/tmp/example",
  "exists": true,
  "is_directory": true,
  "total_directories": 0,
  "total_files": 2,
  "duplicate_groups": [["a.txt", "b.txt"]],
  "entries": [
    {
      "relative_path": "a.txt",
      "entry_type": "file",
      "size_bytes": 10,
      "sha256": "samehash"
    },
    {
      "relative_path": "b.txt",
      "entry_type": "file",
      "size_bytes": 10,
      "sha256": "samehash"
    }
  ]
}
''', '');
}

Future<ProcessResult> _failingProcessRun(
  String executable,
  List<String> arguments,
) async {
  expect(executable, '/tmp/fake-rust-core');
  expect(arguments, <String>['/tmp/example']);

  return ProcessResult(1, 1, '', 'permission denied');
}

// ---------------------------------------------------------------------------
// Streaming path tests
// ---------------------------------------------------------------------------

void _streamingTests() {
  test('buildManifestStreaming emits progress then complete', () async {
    final service = ManifestService(
      rustBinaryResolver: _fakeRustBinary,
      streamingProcessRunner: _streamingSuccessRunner,
    );

    final events = await service
        .buildManifestStreaming('/tmp/example')
        .toList();

    // Should have: counting_complete → progress × 2 → result
    expect(events, hasLength(4));
    expect(events[0], isA<ScanProgress>());
    expect((events[0] as ScanProgress).totalFiles, 2);
    expect((events[0] as ScanProgress).filesScanned, 0);
    expect(events[1], isA<ScanProgress>());
    expect((events[1] as ScanProgress).filesScanned, 1);
    expect(events[2], isA<ScanProgress>());
    expect((events[2] as ScanProgress).filesScanned, 2);
    expect(events[3], isA<ScanComplete>());
    final result = (events[3] as ScanComplete).result;
    expect(result.selectedFolder, '/tmp/example');
    expect(result.totalFiles, 2);
  });

  test('buildManifestStreaming parses modified_secs on entries', () async {
    final service = ManifestService(
      rustBinaryResolver: _fakeRustBinary,
      streamingProcessRunner: _streamingSuccessRunner,
    );

    final events = await service
        .buildManifestStreaming('/tmp/example')
        .toList();

    final complete = events.whereType<ScanComplete>().first;
    final fileEntry = complete.result.entries
        .firstWhere((e) => e.entryType == 'file');
    expect(fileEntry.modifiedSecs, 1700000000);
  });

  test('buildManifestStreaming yields ScanError on missing binary', () async {
    final service = ManifestService(
      rustBinaryResolver: () => null,
      streamingProcessRunner: _streamingSuccessRunner,
    );

    final events = await service
        .buildManifestStreaming('/tmp/example')
        .toList();

    expect(events, hasLength(1));
    expect(events.first, isA<ScanError>());
    expect(
      (events.first as ScanError).message,
      contains('Rust binary not found'),
    );
  });

  test('buildManifestStreaming ignores unknown event types gracefully',
      () async {
    final service = ManifestService(
      rustBinaryResolver: _fakeRustBinary,
      streamingProcessRunner: _streamingWithUnknownEventRunner,
    );

    final events = await service
        .buildManifestStreaming('/tmp/example')
        .toList();

    // Unknown event type should be silently dropped; result should still arrive.
    expect(events.whereType<ScanComplete>(), hasLength(1));
  });
}

Stream<String> _streamingSuccessRunner(
  String executable,
  List<String> arguments,
) async* {
  expect(arguments, contains('--stream-progress'));
  yield '{"type":"counting_complete","total_files":2}';
  yield '{"type":"progress","files_scanned":1,"total_files":2}';
  yield '{"type":"progress","files_scanned":2,"total_files":2}';
  yield '{"type":"result","selected_folder":"/tmp/example","exists":true,'
      '"is_directory":true,"total_directories":1,"total_files":2,'
      '"duplicate_groups":[],"entries":['
      '{"relative_path":"docs","entry_type":"directory","size_bytes":null,'
      '"sha256":null,"modified_secs":null},'
      '{"relative_path":"docs/readme.txt","entry_type":"file","size_bytes":512,'
      '"sha256":"abc123","modified_secs":1700000000}'
      ']}';
}

Stream<String> _streamingWithUnknownEventRunner(
  String executable,
  List<String> arguments,
) async* {
  yield '{"type":"unknown_future_event","data":"ignored"}';
  yield '{"type":"result","selected_folder":"/tmp/example","exists":true,'
      '"is_directory":true,"total_directories":0,"total_files":0,'
      '"duplicate_groups":[],"entries":[]}';
}

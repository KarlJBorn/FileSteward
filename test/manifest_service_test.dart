import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:filesteward/manifest_service.dart';

void main() {
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
  "entries": [
    {
      "relative_path": "docs",
      "entry_type": "directory",
      "size_bytes": null
    },
    {
      "relative_path": "docs/readme.txt",
      "entry_type": "file",
      "size_bytes": 512
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

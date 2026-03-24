import 'dart:convert';
import 'dart:io';

import 'manifest_models.dart';

typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);
typedef RustBinaryResolver = File? Function();

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
  });

  final ProcessRunner processRunner;
  final RustBinaryResolver? rustBinaryResolver;

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

  File? _resolveRustBinary() {
    final resolvedBinary = rustBinaryResolver?.call();
    if (resolvedBinary != null) {
      return resolvedBinary;
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

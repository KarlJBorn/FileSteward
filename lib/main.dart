import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const FileStewardApp());
}

class FileStewardApp extends StatelessWidget {
  const FileStewardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FileSteward',
      debugShowCheckedModeBanner: false,
      home: const FileStewardHomePage(),
    );
  }
}

class ManifestEntry {
  final String relativePath;
  final String entryType;
  final int? sizeBytes;

  ManifestEntry({
    required this.relativePath,
    required this.entryType,
    required this.sizeBytes,
  });

  factory ManifestEntry.fromJson(Map<String, dynamic> json) {
    return ManifestEntry(
      relativePath: json['relative_path'] as String? ?? '',
      entryType: json['entry_type'] as String? ?? 'other',
      sizeBytes: json['size_bytes'] as int?,
    );
  }

  List<String> get pathParts =>
      relativePath.split('/').where((part) => part.isNotEmpty).toList();

  int get depth => pathParts.isEmpty ? 0 : pathParts.length - 1;

  String get leafName => pathParts.isEmpty ? relativePath : pathParts.last;

  String get parentPath {
    if (pathParts.length <= 1) {
      return '';
    }
    return pathParts.sublist(0, pathParts.length - 1).join('/');
  }
}

class ManifestResult {
  final String selectedFolder;
  final bool exists;
  final bool isDirectory;
  final int totalDirectories;
  final int totalFiles;
  final List<ManifestEntry> entries;

  ManifestResult({
    required this.selectedFolder,
    required this.exists,
    required this.isDirectory,
    required this.totalDirectories,
    required this.totalFiles,
    required this.entries,
  });

  factory ManifestResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawEntries = json['entries'] as List<dynamic>? ?? [];

    final entries = rawEntries
        .map((dynamic item) =>
            ManifestEntry.fromJson(item as Map<String, dynamic>))
        .toList();

    entries.sort((a, b) {
      final pathCompare =
          a.relativePath.toLowerCase().compareTo(b.relativePath.toLowerCase());
      if (pathCompare != 0) {
        return pathCompare;
      }

      if (a.entryType == b.entryType) {
        return 0;
      }
      if (a.entryType == 'directory') {
        return -1;
      }
      if (b.entryType == 'directory') {
        return 1;
      }
      return a.entryType.compareTo(b.entryType);
    });

    return ManifestResult(
      selectedFolder: json['selected_folder'] as String? ?? '',
      exists: json['exists'] as bool? ?? false,
      isDirectory: json['is_directory'] as bool? ?? false,
      totalDirectories: json['total_directories'] as int? ?? 0,
      totalFiles: json['total_files'] as int? ?? 0,
      entries: entries,
    );
  }
}

class FileStewardHomePage extends StatefulWidget {
  const FileStewardHomePage({super.key});

  @override
  State<FileStewardHomePage> createState() => _FileStewardHomePageState();
}

class _FileStewardHomePageState extends State<FileStewardHomePage> {
  String? _selectedFolderPath;
  String _statusMessage = 'Choose a folder, then build a recursive manifest.';
  ManifestResult? _manifestResult;
  bool _isRunning = false;

  String get _rustBinaryPath =>
      '/Users/karlborn/development/projects/filesteward_hello/rust_core/target/debug/rust_core';

  Future<void> _chooseFolder() async {
    try {
      final String? directoryPath = await getDirectoryPath();

      if (directoryPath == null || directoryPath.isEmpty) {
        setState(() {
          _statusMessage = 'Folder selection was canceled.';
        });
        return;
      }

      setState(() {
        _selectedFolderPath = directoryPath;
        _manifestResult = null;
        _statusMessage = 'Selected folder:\n$directoryPath';
      });
    } catch (e) {
      setState(() {
        _manifestResult = null;
        _statusMessage = 'Error choosing folder:\n\n$e';
      });
    }
  }

  Future<void> _buildManifest() async {
    if (_selectedFolderPath == null || _selectedFolderPath!.isEmpty) {
      setState(() {
        _manifestResult = null;
        _statusMessage = 'Choose a folder first.';
      });
      return;
    }

    setState(() {
      _isRunning = true;
      _manifestResult = null;
      _statusMessage = 'Building recursive manifest...';
    });

    try {
      final processResult = await Process.run(
        _rustBinaryPath,
        <String>[_selectedFolderPath!],
      );

      final String stdoutText = processResult.stdout.toString().trim();
      final String stderrText = processResult.stderr.toString().trim();

      if (processResult.exitCode != 0) {
        setState(() {
          _statusMessage = 'Rust failed.\n\n$stderrText';
        });
        return;
      }

      final Map<String, dynamic> decodedJson =
          jsonDecode(stdoutText) as Map<String, dynamic>;

      final ManifestResult parsedResult = ManifestResult.fromJson(decodedJson);

      setState(() {
        _manifestResult = parsedResult;
        _statusMessage = 'Recursive manifest completed.';
      });
    } catch (e) {
      setState(() {
        _manifestResult = null;
        _statusMessage = 'Error running Rust:\n\n$e';
      });
    } finally {
      setState(() {
        _isRunning = false;
      });
    }
  }

  IconData _iconForEntryType(String entryType) {
    switch (entryType) {
      case 'directory':
        return Icons.folder;
      case 'file':
        return Icons.insert_drive_file;
      default:
        return Icons.help_outline;
    }
  }

  String _formatSize(int? sizeBytes) {
    if (sizeBytes == null) {
      return '';
    }
    if (sizeBytes < 1024) {
      return '$sizeBytes B';
    }
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    if (sizeBytes < 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Widget _buildSummaryCard(ManifestResult result) {
    final int totalEntries = result.entries.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 24,
          runSpacing: 16,
          alignment: WrapAlignment.spaceEvenly,
          children: <Widget>[
            _SummaryItem(
              label: 'Entries',
              value: totalEntries.toString(),
            ),
            _SummaryItem(
              label: 'Folders',
              value: result.totalDirectories.toString(),
            ),
            _SummaryItem(
              label: 'Files',
              value: result.totalFiles.toString(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildManifestTile(ManifestEntry entry) {
    final double leftIndent = entry.depth * 20.0;

    String subtitle = entry.entryType;
    if (entry.parentPath.isNotEmpty) {
      subtitle = '${entry.parentPath} • $subtitle';
    }
    if (entry.sizeBytes != null) {
      subtitle = '$subtitle • ${_formatSize(entry.sizeBytes)}';
    }

    return Padding(
      padding: EdgeInsets.only(left: leftIndent),
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(_iconForEntryType(entry.entryType)),
        title: Text(entry.leafName),
        subtitle: Text(subtitle),
      ),
    );
  }

  List<Widget> _buildResultWidgets() {
    if (_manifestResult == null) {
      return <Widget>[];
    }

    return <Widget>[
      Text(
        'Exists: ${_manifestResult!.exists ? "yes" : "no"}',
        style: const TextStyle(fontSize: 16),
      ),
      const SizedBox(height: 8),
      Text(
        'Is directory: ${_manifestResult!.isDirectory ? "yes" : "no"}',
        style: const TextStyle(fontSize: 16),
      ),
      const SizedBox(height: 16),
      _buildSummaryCard(_manifestResult!),
      const SizedBox(height: 16),
      const Text(
        'Recursive manifest',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      if (_manifestResult!.entries.isEmpty)
        const Text(
          'This folder contains no recursive entries.',
          style: TextStyle(fontSize: 16),
        )
      else
        ..._manifestResult!.entries.map(_buildManifestTile),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final String displayedPath = _selectedFolderPath ?? 'No folder selected';

    return Scaffold(
      appBar: AppBar(
        title: const Text('FileSteward'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Selected folder',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              displayedPath,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            Text(
              _statusMessage,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            ..._buildResultWidgets(),
          ],
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Row(
          children: <Widget>[
            Expanded(
              child: ElevatedButton(
                onPressed: _chooseFolder,
                child: const Text('Choose Folder'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: ElevatedButton(
                onPressed: _isRunning ? null : _buildManifest,
                child: Text(_isRunning ? 'Running...' : 'Build Manifest'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final String label;
  final String value;

  const _SummaryItem({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
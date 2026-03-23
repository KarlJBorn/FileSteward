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

class ChildEntry {
  final String name;
  final String entryType;

  ChildEntry({
    required this.name,
    required this.entryType,
  });

  factory ChildEntry.fromJson(Map<String, dynamic> json) {
    return ChildEntry(
      name: json['name'] as String? ?? '',
      entryType: json['entry_type'] as String? ?? 'other',
    );
  }
}

class FolderInspectionResult {
  final String selectedFolder;
  final bool exists;
  final bool isDirectory;
  final int directChildEntries;
  final int directDirectories;
  final int directFiles;
  final int directOtherEntries;
  final List<ChildEntry> children;

  FolderInspectionResult({
    required this.selectedFolder,
    required this.exists,
    required this.isDirectory,
    required this.directChildEntries,
    required this.directDirectories,
    required this.directFiles,
    required this.directOtherEntries,
    required this.children,
  });

  factory FolderInspectionResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawChildren = json['children'] as List<dynamic>? ?? [];

    return FolderInspectionResult(
      selectedFolder: json['selected_folder'] as String? ?? '',
      exists: json['exists'] as bool? ?? false,
      isDirectory: json['is_directory'] as bool? ?? false,
      directChildEntries: json['direct_child_entries'] as int? ?? 0,
      directDirectories: json['direct_directories'] as int? ?? 0,
      directFiles: json['direct_files'] as int? ?? 0,
      directOtherEntries: json['direct_other_entries'] as int? ?? 0,
      children: rawChildren
          .map((dynamic item) =>
              ChildEntry.fromJson(item as Map<String, dynamic>))
          .toList(),
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
  String _statusMessage = 'Choose a folder, then inspect it with Rust.';
  FolderInspectionResult? _inspectionResult;
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
        _inspectionResult = null;
        _statusMessage = 'Selected folder:\n$directoryPath';
      });
    } catch (e) {
      setState(() {
        _inspectionResult = null;
        _statusMessage = 'Error choosing folder:\n\n$e';
      });
    }
  }

  Future<void> _inspectFolder() async {
    if (_selectedFolderPath == null || _selectedFolderPath!.isEmpty) {
      setState(() {
        _inspectionResult = null;
        _statusMessage = 'Choose a folder first.';
      });
      return;
    }

    setState(() {
      _isRunning = true;
      _inspectionResult = null;
      _statusMessage = 'Running Rust inspection...';
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

      final FolderInspectionResult parsedResult =
          FolderInspectionResult.fromJson(decodedJson);

      setState(() {
        _inspectionResult = parsedResult;
        _statusMessage = 'Rust inspection completed.';
      });
    } catch (e) {
      setState(() {
        _inspectionResult = null;
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

  Widget _buildSummaryCard(FolderInspectionResult result) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 24,
          runSpacing: 16,
          alignment: WrapAlignment.spaceEvenly,
          children: <Widget>[
            _SummaryItem(
              label: 'Total',
              value: result.directChildEntries.toString(),
            ),
            _SummaryItem(
              label: 'Folders',
              value: result.directDirectories.toString(),
            ),
            _SummaryItem(
              label: 'Files',
              value: result.directFiles.toString(),
            ),
            _SummaryItem(
              label: 'Other',
              value: result.directOtherEntries.toString(),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildResultWidgets() {
    if (_inspectionResult == null) {
      return <Widget>[];
    }

    return <Widget>[
      Text(
        'Exists: ${_inspectionResult!.exists ? "yes" : "no"}',
        style: const TextStyle(fontSize: 16),
      ),
      const SizedBox(height: 8),
      Text(
        'Is directory: ${_inspectionResult!.isDirectory ? "yes" : "no"}',
        style: const TextStyle(fontSize: 16),
      ),
      const SizedBox(height: 16),
      _buildSummaryCard(_inspectionResult!),
      const SizedBox(height: 16),
      const Text(
        'Direct children',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      if (_inspectionResult!.children.isEmpty)
        const Text(
          'This folder has no direct child entries.',
          style: TextStyle(fontSize: 16),
        )
      else
        ..._inspectionResult!.children.map(
          (ChildEntry child) => ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(_iconForEntryType(child.entryType)),
            title: Text(child.name),
            subtitle: Text(child.entryType),
          ),
        ),
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
                onPressed: _isRunning ? null : _inspectFolder,
                child: Text(_isRunning ? 'Running...' : 'Inspect Folder'),
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
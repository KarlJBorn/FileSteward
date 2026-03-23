import 'dart:convert'; // Needed to decode JSON returned by Rust.
import 'dart:io'; // Needed for Process.run to launch the Rust executable.

import 'package:file_selector/file_selector.dart'; // Folder picker plugin.
import 'package:flutter/material.dart';

void main() {
  runApp(const FileStewardApp());
}

/// Top-level Flutter application object.
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

/// Represents one child entry returned by Rust.
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

/// Represents the full folder inspection result returned by Rust.
class FolderInspectionResult {
  final String selectedFolder;
  final bool exists;
  final bool isDirectory;
  final int directChildEntries;
  final List<ChildEntry> children;

  FolderInspectionResult({
    required this.selectedFolder,
    required this.exists,
    required this.isDirectory,
    required this.directChildEntries,
    required this.children,
  });

  factory FolderInspectionResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawChildren = json['children'] as List<dynamic>? ?? [];

    return FolderInspectionResult(
      selectedFolder: json['selected_folder'] as String? ?? '',
      exists: json['exists'] as bool? ?? false,
      isDirectory: json['is_directory'] as bool? ?? false,
      directChildEntries: json['direct_child_entries'] as int? ?? 0,
      children: rawChildren
          .map((dynamic item) =>
              ChildEntry.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Main screen for the current folder-inspection milestone.
class FileStewardHomePage extends StatefulWidget {
  const FileStewardHomePage({super.key});

  @override
  State<FileStewardHomePage> createState() => _FileStewardHomePageState();
}

class _FileStewardHomePageState extends State<FileStewardHomePage> {
  /// Folder selected by the user in the macOS folder picker.
  String? _selectedFolderPath;

  /// Raw status or error text shown above the structured results.
  String _statusMessage = 'Choose a folder, then inspect it with Rust.';

  /// Parsed inspection result returned by Rust.
  FolderInspectionResult? _inspectionResult;

  /// Prevents repeated clicks while Rust is running.
  bool _isRunning = false;

  /// Current hard-coded path to the compiled Rust executable.
  ///
  /// This is still temporary and development-only.
  String get _rustBinaryPath =>
      '/Users/karlborn/development/projects/filesteward_hello/rust_core/target/debug/rust_core';

  /// Opens a macOS folder chooser and stores the selected path.
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

  /// Runs the Rust executable and passes the selected folder path.
  /// Rust returns JSON, which we decode into a Dart object.
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

  /// Builds a simple icon for the child entry type.
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

  @override
  Widget build(BuildContext context) {
    final String displayedPath = _selectedFolderPath ?? 'No folder selected';

    return Scaffold(
      appBar: AppBar(
        title: const Text('FileSteward'),
      ),
      body: Padding(
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
            if (_inspectionResult != null) ...<Widget>[
              Text(
                'Exists: ${_inspectionResult!.exists ? "yes" : "no"}',
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                'Is directory: ${_inspectionResult!.isDirectory ? "yes" : "no"}',
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                'Direct child entries: ${_inspectionResult!.directChildEntries}',
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 16),
              const Text(
                'Direct children',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _inspectionResult!.children.isEmpty
                    ? const Text(
                        'This folder has no direct child entries.',
                        style: TextStyle(fontSize: 16),
                      )
                    : ListView.builder(
                        itemCount: _inspectionResult!.children.length,
                        itemBuilder: (BuildContext context, int index) {
                          final ChildEntry child =
                              _inspectionResult!.children[index];

                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(_iconForEntryType(child.entryType)),
                            title: Text(child.name),
                            subtitle: Text(child.entryType),
                          );
                        },
                      ),
              ),
            ] else
              const Expanded(
                child: SizedBox.shrink(),
              ),
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
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'manifest_filter.dart';
import 'manifest_models.dart';
import 'manifest_service.dart';

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

class FileStewardHomePage extends StatefulWidget {
  const FileStewardHomePage({super.key});

  @override
  State<FileStewardHomePage> createState() => _FileStewardHomePageState();
}

class _FileStewardHomePageState extends State<FileStewardHomePage> {
  final ManifestService _manifestService = const ManifestService();
  String? _selectedFolderPath;
  String _statusMessage = 'Choose a folder, then build a recursive manifest.';
  ManifestResult? _manifestResult;
  bool _isRunning = false;
  ManifestEntryFilter _entryFilter = ManifestEntryFilter.all;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_handleSearchChanged);
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_handleSearchChanged)
      ..dispose();
    super.dispose();
  }

  void _handleSearchChanged() {
    final nextQuery = _searchController.text;
    if (nextQuery == _searchQuery) {
      return;
    }
    setState(() {
      _searchQuery = nextQuery;
    });
  }

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
        _entryFilter = ManifestEntryFilter.all;
        _searchController.clear();
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
      final ManifestResult parsedResult = await _manifestService.buildManifest(
        _selectedFolderPath!,
      );

      setState(() {
        _manifestResult = parsedResult;
        _entryFilter = ManifestEntryFilter.all;
        _searchController.clear();
        _statusMessage = 'Recursive manifest completed.';
      });
    } on ManifestServiceException catch (e) {
      setState(() {
        _manifestResult = null;
        _statusMessage = e.message;
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
    final int duplicateGroupCount = result.duplicateGroups.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 24,
          runSpacing: 16,
          alignment: WrapAlignment.spaceEvenly,
          children: <Widget>[
            _SummaryItem(label: 'Entries', value: totalEntries.toString()),
            _SummaryItem(
              label: 'Folders',
              value: result.totalDirectories.toString(),
            ),
            _SummaryItem(label: 'Files', value: result.totalFiles.toString()),
            _SummaryItem(
              label: 'Dup. Groups',
              value: duplicateGroupCount.toString(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDuplicateGroups(ManifestResult result) {
    if (result.duplicateGroups.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 16),
        Text(
          'Duplicate Groups (${result.duplicateGroups.length})',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        ...result.duplicateGroups.asMap().entries.map((entry) {
          final int index = entry.key;
          final List<String> group = entry.value;
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Group ${index + 1} — ${group.length} identical files',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  ...group.map(
                    (path) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: <Widget>[
                          const Icon(
                            Icons.content_copy,
                            size: 14,
                            color: Colors.orange,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              path,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
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

  List<ManifestEntry> get _visibleEntries {
    final manifestResult = _manifestResult;
    if (manifestResult == null) {
      return <ManifestEntry>[];
    }

    return filterManifestEntries(
      entries: manifestResult.entries,
      filter: _entryFilter,
      query: _searchQuery,
    );
  }

  Widget _buildReviewControls(ManifestResult result) {
    final visibleEntries = _visibleEntries;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text(
          'Review manifest',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            labelText: 'Search paths',
            hintText: 'Filter by relative path',
            border: const OutlineInputBorder(),
            suffixIcon: _searchQuery.trim().isEmpty
                ? null
                : IconButton(
                    onPressed: _searchController.clear,
                    icon: const Icon(Icons.clear),
                    tooltip: 'Clear search',
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            ChoiceChip(
              label: const Text('All'),
              selected: _entryFilter == ManifestEntryFilter.all,
              onSelected: (_) {
                setState(() {
                  _entryFilter = ManifestEntryFilter.all;
                });
              },
            ),
            ChoiceChip(
              label: const Text('Folders'),
              selected: _entryFilter == ManifestEntryFilter.directories,
              onSelected: (_) {
                setState(() {
                  _entryFilter = ManifestEntryFilter.directories;
                });
              },
            ),
            ChoiceChip(
              label: const Text('Files'),
              selected: _entryFilter == ManifestEntryFilter.files,
              onSelected: (_) {
                setState(() {
                  _entryFilter = ManifestEntryFilter.files;
                });
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Showing ${visibleEntries.length} of ${result.entries.length} entries',
          style: const TextStyle(fontSize: 16),
        ),
      ],
    );
  }

  List<Widget> _buildResultWidgets() {
    final manifestResult = _manifestResult;
    if (manifestResult == null) {
      return <Widget>[];
    }

    final visibleEntries = _visibleEntries;

    return <Widget>[
      Text(
        'Exists: ${manifestResult.exists ? "yes" : "no"}',
        style: const TextStyle(fontSize: 16),
      ),
      const SizedBox(height: 8),
      Text(
        'Is directory: ${manifestResult.isDirectory ? "yes" : "no"}',
        style: const TextStyle(fontSize: 16),
      ),
      const SizedBox(height: 16),
      _buildSummaryCard(manifestResult),
      const SizedBox(height: 16),
      _buildReviewControls(manifestResult),
      const SizedBox(height: 16),
      const Text(
        'Recursive manifest',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      if (manifestResult.entries.isEmpty)
        const Text(
          'This folder contains no recursive entries.',
          style: TextStyle(fontSize: 16),
        )
      else if (visibleEntries.isEmpty)
        const Text(
          'No entries match the current review filters.',
          style: TextStyle(fontSize: 16),
        )
      else
        ...visibleEntries.map(_buildManifestTile),
      _buildDuplicateGroups(manifestResult),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final String displayedPath = _selectedFolderPath ?? 'No folder selected';

    return Scaffold(
      appBar: AppBar(title: const Text('FileSteward')),
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
            Text(displayedPath, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 24),
            Text(_statusMessage, style: const TextStyle(fontSize: 16)),
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

  const _SummaryItem({required this.label, required this.value});

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

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'folder_scan_state.dart';
import 'manifest_filter.dart';
import 'manifest_models.dart';
import 'manifest_service.dart';
import 'scan_events.dart';
import 'unified_manifest.dart';

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

  List<FolderScanState> _folders = [];
  UnifiedManifest? _unifiedManifest;
  bool _isScanning = false;
  bool _forceRescan = false;

  ManifestEntryFilter _entryFilter = ManifestEntryFilter.all;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  DateTime _lastProgressUpdate = DateTime(0);

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
    if (nextQuery == _searchQuery) return;
    setState(() => _searchQuery = nextQuery);
  }

  // ---------------------------------------------------------------------------
  // Folder management
  // ---------------------------------------------------------------------------

  Future<void> _addFolder() async {
    try {
      final String? directoryPath = await getDirectoryPath();
      if (directoryPath == null || directoryPath.isEmpty) return;

      // Ignore if already in the list.
      if (_folders.any((f) => f.folderPath == directoryPath)) return;

      setState(() {
        _folders = [..._folders, FolderScanState(folderPath: directoryPath)];
        _unifiedManifest = null;
      });
    } catch (e) {
      // Ignore cancellation errors.
    }
  }

  void _removeFolder(int index) {
    setState(() {
      _folders = [..._folders]..removeAt(index);
      _unifiedManifest = null;
    });
  }

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  Future<void> _scanAll() async {
    if (_folders.isEmpty) return;

    setState(() {
      _isScanning = true;
      _unifiedManifest = null;
      // Reset all folder states to pending.
      _folders = _folders
          .map((f) => FolderScanState(folderPath: f.folderPath))
          .toList();
    });

    for (int i = 0; i < _folders.length; i++) {
      // Mark this folder as scanning.
      setState(() {
        _folders[i] = _folders[i].copyWith(scanProgress: 0.0);
      });

      await for (final ScanEvent event in _manifestService
          .buildManifestStreaming(
        _folders[i].folderPath,
        forceRescan: _forceRescan,
      )) {
        switch (event) {
          case ScanProgress(:final filesScanned, :final totalFiles):
            final now = DateTime.now();
            if (now.difference(_lastProgressUpdate).inMilliseconds >= 33) {
              _lastProgressUpdate = now;
              setState(() {
                _folders[i] = _folders[i].copyWith(
                  scanProgress:
                      totalFiles > 0 ? filesScanned / totalFiles : 0.0,
                  filesScanned: filesScanned,
                  totalFiles: totalFiles,
                );
              });
            }
          case ScanComplete(:final result):
            setState(() {
              _folders[i] = _folders[i].copyWith(
                result: result,
                clearScanProgress: true,
              );
            });
          case ScanError(:final message):
            setState(() {
              _folders[i] = _folders[i].copyWith(
                errorMessage: message,
                clearScanProgress: true,
              );
            });
        }
      }
    }

    // Compute unified manifest from all completed scans.
    final completedResults = _folders
        .where((f) => f.result != null)
        .map((f) => f.result!)
        .toList();

    setState(() {
      _unifiedManifest =
          completedResults.isNotEmpty ? UnifiedManifest.from(completedResults) : null;
      _isScanning = false;
    });
  }

  // ---------------------------------------------------------------------------
  // Formatting helpers
  // ---------------------------------------------------------------------------

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
    if (sizeBytes == null) return '';
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    if (sizeBytes < 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatDate(int modifiedSecs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(modifiedSecs * 1000);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }

  String _shortPath(String path) {
    final parts = path.split('/');
    return parts.length > 2 ? '…/${parts.last}' : path;
  }

  // ---------------------------------------------------------------------------
  // UI builders — folder list
  // ---------------------------------------------------------------------------

  Widget _buildFolderList() {
    if (_folders.isEmpty) {
      return const Text(
        'No folders added yet. Add one or more source folders to scan.',
        style: TextStyle(fontSize: 15, color: Colors.grey),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _folders.asMap().entries.map((entry) {
        final int index = entry.key;
        final FolderScanState folder = entry.value;
        return _buildFolderTile(index, folder);
      }).toList(),
    );
  }

  Widget _buildFolderTile(int index, FolderScanState folder) {
    final Widget statusIcon;
    if (folder.isScanning) {
      statusIcon = const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (folder.isComplete) {
      statusIcon = const Icon(Icons.check_circle, color: Colors.green, size: 18);
    } else if (folder.hasError) {
      statusIcon = const Icon(Icons.error_outline, color: Colors.red, size: 18);
    } else {
      statusIcon = const Icon(Icons.radio_button_unchecked, size: 18, color: Colors.grey);
    }

    String subtitle = folder.folderPath;
    if (folder.isScanning && folder.totalFiles > 0) {
      subtitle = 'Scanning… ${folder.filesScanned} / ${folder.totalFiles} files';
    } else if (folder.isComplete) {
      final r = folder.result!;
      subtitle = '${r.totalFiles} files · ${r.totalDirectories} folders';
    } else if (folder.hasError) {
      subtitle = folder.errorMessage ?? 'Error';
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                statusIcon,
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _shortPath(folder.folderPath),
                    style: const TextStyle(fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!_isScanning)
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: 'Remove folder',
                    onPressed: () => _removeFolder(index),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (folder.isScanning)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: LinearProgressIndicator(
                  value: folder.totalFiles > 0 ? folder.scanProgress : null,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI builders — unified results
  // ---------------------------------------------------------------------------

  Widget _buildUnifiedSummaryCard(UnifiedManifest manifest) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 24,
          runSpacing: 16,
          alignment: WrapAlignment.spaceEvenly,
          children: <Widget>[
            _SummaryItem(
              label: 'Sources',
              value: manifest.sources.length.toString(),
            ),
            _SummaryItem(
              label: 'Files',
              value: manifest.totalFiles.toString(),
            ),
            _SummaryItem(
              label: 'Folders',
              value: manifest.totalDirectories.toString(),
            ),
            _SummaryItem(
              label: 'Cross-Source Dups',
              value: manifest.crossSourceGroupCount.toString(),
              highlight: manifest.crossSourceGroupCount > 0,
            ),
            _SummaryItem(
              label: 'Within-Source Dups',
              value: manifest.withinSourceGroupCount.toString(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCrossSourceGroups(UnifiedManifest manifest) {
    if (manifest.crossSourceGroups.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            const Icon(Icons.compare_arrows, color: Colors.deepOrange),
            const SizedBox(width: 8),
            Text(
              'Cross-Source Duplicates (${manifest.crossSourceGroups.length})',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'These files appear identically in more than one source folder.',
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        ...manifest.crossSourceGroups.asMap().entries.map((entry) {
          final int index = entry.key;
          final CrossSourceGroup group = entry.value;
          return _buildCrossSourceGroupCard(index, group);
        }),
      ],
    );
  }

  Widget _buildCrossSourceGroupCard(int index, CrossSourceGroup group) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Colors.deepOrange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Group ${index + 1} — ${group.members.length} identical copies across sources',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            ...group.members.map((member) {
              final sizeLabel = _formatSize(member.entry.sizeBytes);
              final dateLabel = member.entry.modifiedSecs != null
                  ? _formatDate(member.entry.modifiedSecs!)
                  : '';
              final meta = [sizeLabel, dateLabel]
                  .where((s) => s.isNotEmpty)
                  .join(' · ');
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.content_copy, size: 14, color: Colors.deepOrange),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            member.absolutePath,
                            style: const TextStyle(fontSize: 12),
                          ),
                          if (meta.isNotEmpty)
                            Text(
                              meta,
                              style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildWithinSourceGroups(UnifiedManifest manifest) {
    final allGroups = <MapEntry<String, List<String>>>[];
    for (final source in manifest.sources) {
      for (final group in source.duplicateGroups) {
        allGroups.add(MapEntry(source.selectedFolder, group));
      }
    }

    if (allGroups.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 16),
        Text(
          'Within-Source Duplicates (${allGroups.length})',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        ...allGroups.asMap().entries.map((outerEntry) {
          final int index = outerEntry.key;
          final String sourceFolder = outerEntry.value.key;
          final List<String> group = outerEntry.value.value;

          // Look up entry metadata from the corresponding source.
          final source = manifest.sources
              .firstWhere((s) => s.selectedFolder == sourceFolder);

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
                  Text(
                    _shortPath(sourceFolder),
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 4),
                  ...group.map((path) {
                    final ManifestEntry? entry = source.entries
                        .where((e) => e.relativePath == path)
                        .firstOrNull;
                    final sizeLabel = _formatSize(entry?.sizeBytes);
                    final dateLabel = entry?.modifiedSecs != null
                        ? _formatDate(entry!.modifiedSecs!)
                        : '';
                    final meta = [sizeLabel, dateLabel]
                        .where((s) => s.isNotEmpty)
                        .join(' · ');
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: <Widget>[
                          const Icon(Icons.content_copy,
                              size: 14, color: Colors.orange),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(path,
                                    style: const TextStyle(fontSize: 13)),
                                if (meta.isNotEmpty)
                                  Text(meta,
                                      style: const TextStyle(
                                          fontSize: 11, color: Colors.grey)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // UI builders — per-source manifest list (single-source only)
  // ---------------------------------------------------------------------------

  Widget _buildManifestReview(UnifiedManifest manifest) {
    if (manifest.sources.length != 1) {
      return const Padding(
        padding: EdgeInsets.only(top: 16),
        child: Text(
          'Add a single folder to browse its full file manifest.',
          style: TextStyle(fontSize: 14, color: Colors.grey),
        ),
      );
    }

    final result = manifest.sources.first;
    final visibleEntries = filterManifestEntries(
      entries: result.entries,
      filter: _entryFilter,
      query: _searchQuery,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 16),
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
              onSelected: (_) =>
                  setState(() => _entryFilter = ManifestEntryFilter.all),
            ),
            ChoiceChip(
              label: const Text('Folders'),
              selected: _entryFilter == ManifestEntryFilter.directories,
              onSelected: (_) =>
                  setState(() => _entryFilter = ManifestEntryFilter.directories),
            ),
            ChoiceChip(
              label: const Text('Files'),
              selected: _entryFilter == ManifestEntryFilter.files,
              onSelected: (_) =>
                  setState(() => _entryFilter = ManifestEntryFilter.files),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Showing ${visibleEntries.length} of ${result.entries.length} entries',
          style: const TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 8),
        if (visibleEntries.isEmpty)
          const Text(
            'No entries match the current filters.',
            style: TextStyle(fontSize: 14, color: Colors.grey),
          )
        else
          ...visibleEntries.map(_buildManifestTile),
      ],
    );
  }

  Widget _buildManifestTile(ManifestEntry entry) {
    final double leftIndent = entry.depth * 20.0;
    String subtitle = entry.entryType;
    if (entry.parentPath.isNotEmpty) subtitle = '${entry.parentPath} • $subtitle';
    if (entry.sizeBytes != null) subtitle = '$subtitle • ${_formatSize(entry.sizeBytes)}';

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

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final unified = _unifiedManifest;

    return Scaffold(
      appBar: AppBar(title: const Text('FileSteward')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 140),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Source Folders',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            _buildFolderList(),
            if (unified != null) ...[
              const SizedBox(height: 24),
              _buildUnifiedSummaryCard(unified),
              _buildCrossSourceGroups(unified),
              _buildWithinSourceGroups(unified),
              _buildManifestReview(unified),
            ],
          ],
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isScanning ? null : _addFolder,
                    icon: const Icon(Icons.add),
                    label: const Text('Add Folder'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed:
                        (_isScanning || _folders.isEmpty) ? null : _scanAll,
                    icon: const Icon(Icons.search),
                    label: Text(_isScanning ? 'Scanning…' : 'Scan All'),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                const Text('Force rescan', style: TextStyle(fontSize: 13)),
                Switch(
                  value: _forceRescan,
                  onChanged: _isScanning
                      ? null
                      : (value) => setState(() => _forceRescan = value),
                ),
              ],
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
  final bool highlight;

  const _SummaryItem({
    required this.label,
    required this.value,
    this.highlight = false,
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
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: highlight ? Colors.deepOrange : null,
            ),
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

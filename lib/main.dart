import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'manifest_models.dart';
import 'manifest_service.dart';
import 'scan_events.dart';

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

  // Inventory pass (fast, auto-runs after folder selection)
  InventoryResult? _inventoryResult;
  bool _isInventoryRunning = false;
  bool _sourcesExpanded = false;
  Set<String> _selectedExtensions = {};

  // Full manifest (streaming hashing pass)
  ManifestResult? _manifestResult;
  bool _isRunning = false;
  double _scanProgress = 0.0;
  int _filesScanned = 0;
  int _totalScanFiles = 0;
  bool _forceRescan = false;

  DateTime _lastProgressUpdate = DateTime(0);

  // ---------------------------------------------------------------------------
  // Folder management
  // ---------------------------------------------------------------------------

  Future<void> _addFolder() async {
    try {
      final String? directoryPath = await getDirectoryPath();
      if (directoryPath == null || directoryPath.isEmpty) return;

      setState(() {
        _selectedFolderPath = directoryPath;
        _inventoryResult = null;
        _selectedExtensions = {};
        _manifestResult = null;
      });
      unawaited(_runInventory(directoryPath));
    } catch (e) {
      // Ignore cancellation errors.
    }
  }

  // ---------------------------------------------------------------------------
  // Inventory pass
  // ---------------------------------------------------------------------------

  Future<void> _runInventory(String folderPath) async {
    setState(() {
      _isInventoryRunning = true;
    });

    try {
      final result = await _manifestService.buildInventory(folderPath);
      setState(() {
        _inventoryResult = result;
        _selectedExtensions = result.extensions.map((s) => s.extension).toSet();
      });
    } on ManifestServiceException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error running inventory:\n\n$e')),
        );
      }
    } finally {
      setState(() {
        _isInventoryRunning = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Manifest scan (streaming hashing pass)
  // ---------------------------------------------------------------------------

  Future<void> _buildManifest() async {
    final folderPath = _selectedFolderPath;
    if (folderPath == null) return;

    setState(() {
      _isRunning = true;
      _manifestResult = null;
      _scanProgress = 0.0;
      _filesScanned = 0;
      _totalScanFiles = 0;
    });

    await for (final ScanEvent event in _manifestService.buildManifestStreaming(
      folderPath,
      forceRescan: _forceRescan,
    )) {
      switch (event) {
        case ScanProgress(:final filesScanned, :final totalFiles):
          final now = DateTime.now();
          if (now.difference(_lastProgressUpdate).inMilliseconds >= 33) {
            _lastProgressUpdate = now;
            setState(() {
              _filesScanned = filesScanned;
              _totalScanFiles = totalFiles;
              _scanProgress =
                  totalFiles > 0 ? filesScanned / totalFiles : 0.0;
            });
          }
        case ScanComplete(:final result):
          setState(() {
            _manifestResult = result;
          });
        case ScanError(:final message):
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(message)),
            );
          }
      }
    }

    setState(() {
      _isRunning = false;
    });
  }

  // ---------------------------------------------------------------------------
  // Computed getters
  // ---------------------------------------------------------------------------

  int get _totalInventoryBytes =>
      _inventoryResult?.extensions.fold<int>(0, (s, e) => s + e.totalBytes) ??
      0;

  int get _uniqueFileCount {
    final result = _manifestResult;
    if (result == null) return 0;
    final duplicated =
        result.duplicateGroups.expand((g) => g).toSet().length;
    return result.totalFiles - duplicated;
  }

  int get _duplicateFileCount {
    final result = _manifestResult;
    if (result == null) return 0;
    return result.duplicateGroups.expand((g) => g).toSet().length;
  }

  int get _crossDirDuplicateCount {
    final result = _manifestResult;
    if (result == null) return 0;
    return result.duplicateGroups.where((g) {
      final dirs = g.map((p) {
        final idx = p.lastIndexOf('/');
        return idx < 0 ? '' : p.substring(0, idx);
      }).toSet();
      return dirs.length > 1;
    }).length;
  }

  int get _potentialSavingsBytes {
    final result = _manifestResult;
    if (result == null) return 0;
    int total = 0;
    for (final group in result.duplicateGroups) {
      for (final path in group.skip(1)) {
        final entry = result.entries
            .where((e) => e.relativePath == path)
            .firstOrNull;
        total += entry?.sizeBytes ?? 0;
      }
    }
    return total;
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
  // UI builders — Scan Summary
  // ---------------------------------------------------------------------------

  Widget _buildScanSummaryCard() {
    final inventory = _inventoryResult;
    if (inventory == null) return const SizedBox.shrink();

    final hasScan = _manifestResult != null;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            onTap: () =>
                setState(() => _sourcesExpanded = !_sourcesExpanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: <Widget>[
                  const Text(
                    'Scan Summary',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _sourcesExpanded
                        ? 'Collapse ▴'
                        : 'Expand for Source Details ▾',
                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Wrap(
              spacing: 24,
              runSpacing: 16,
              alignment: WrapAlignment.spaceEvenly,
              children: <Widget>[
                _SummaryItem(
                  label: 'Files',
                  value: inventory.totalFiles.toString(),
                ),
                _SummaryItem(
                  label: 'Size',
                  value: _formatSize(_totalInventoryBytes),
                ),
                if (hasScan) ...<Widget>[
                  _SummaryItem(
                    label: 'Unique',
                    value: _uniqueFileCount.toString(),
                    color: Colors.green[700],
                  ),
                  _SummaryItem(
                    label: 'Duplicates',
                    value: _duplicateFileCount.toString(),
                    color: Colors.orange[700],
                  ),
                  _SummaryItem(
                    label: 'Cross-Dir Dups',
                    value: _crossDirDuplicateCount.toString(),
                    color: Colors.deepOrange[700],
                  ),
                ],
              ],
            ),
          ),
          if (hasScan && _potentialSavingsBytes > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green[200]!),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.savings, color: Colors.green[700]),
                    const SizedBox(width: 8),
                    Text(
                      'Potential savings: ${_formatSize(_potentialSavingsBytes)}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.green[700],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_sourcesExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: _buildSourceDetailCard(inventory),
            ),
        ],
      ),
    );
  }

  Widget _buildSourceDetailCard(InventoryResult inventory) {
    return Card(
      color: Colors.grey[50],
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.grey[300]!),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 24,
          runSpacing: 12,
          alignment: WrapAlignment.spaceEvenly,
          children: <Widget>[
            _SummaryItem(
              label: 'Files',
              value: inventory.totalFiles.toString(),
            ),
            _SummaryItem(
              label: 'Size',
              value: _formatSize(_totalInventoryBytes),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI builders — Scan Scope
  // ---------------------------------------------------------------------------

  Widget _buildScanScopeCard() {
    final inventory = _inventoryResult;
    if (inventory == null || inventory.extensions.isEmpty) {
      return const SizedBox.shrink();
    }

    final hasScan = _manifestResult != null;
    final maxCount = inventory.extensions.fold<int>(
      0,
      (m, s) => s.count > m ? s.count : m,
    );

    final visibleExtensions = hasScan
        ? inventory.extensions
            .where((s) => _selectedExtensions.contains(s.extension))
            .toList()
        : inventory.extensions;
    final excludedCount =
        inventory.extensions.length - visibleExtensions.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Scan Scope',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Select the file types to include in all analysis passes.',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            const SizedBox(height: 12),
            ...visibleExtensions.map((stat) {
              final label =
                  stat.extension.isEmpty ? '(no extension)' : stat.extension;
              final isSelected = _selectedExtensions.contains(stat.extension);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: isSelected,
                        onChanged: hasScan
                            ? null
                            : (checked) {
                                setState(() {
                                  if (checked == true) {
                                    _selectedExtensions.add(stat.extension);
                                  } else {
                                    _selectedExtensions
                                        .remove(stat.extension);
                                  }
                                });
                              },
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 72,
                      child: Text(
                        label,
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: maxCount > 0 ? stat.count / maxCount : 0,
                        backgroundColor: Colors.grey[200],
                        color: isSelected ? Colors.blue : Colors.grey[400],
                        minHeight: 6,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${stat.count}  ${_formatSize(stat.totalBytes)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[700],
                      ),
                    ),
                  ],
                ),
              );
            }),
            if (hasScan && excludedCount > 0) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '$excludedCount excluded type${excludedCount > 1 ? 's' : ''} hidden',
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI builders — manifest entries
  // ---------------------------------------------------------------------------

  Widget _buildManifestTile(ManifestEntry entry) {
    final double leftIndent = entry.depth * 20.0;
    String subtitle = entry.entryType;
    if (entry.parentPath.isNotEmpty) {
      subtitle = '${entry.parentPath} • $subtitle';
    }
    if (entry.sizeBytes != null) {
      subtitle = '$subtitle • ${_formatSize(entry.sizeBytes)}';
    }
    if (entry.modifiedSecs != null) {
      subtitle = '$subtitle • ${_formatDate(entry.modifiedSecs!)}';
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
    final manifestResult = _manifestResult;
    if (manifestResult == null) return <Widget>[];
    return manifestResult.entries.map(_buildManifestTile).toList();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final folderPath = _selectedFolderPath;
    final displayedPath = folderPath != null
        ? _shortPath(folderPath)
        : 'No folder selected';

    return Scaffold(
      appBar: AppBar(title: const Text('FileSteward')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 140),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(displayedPath, style: const TextStyle(fontSize: 16)),
            if (_isInventoryRunning)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: LinearProgressIndicator(),
              ),
            if (_isRunning) ...<Widget>[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: _totalScanFiles > 0 ? _scanProgress : null,
              ),
              const SizedBox(height: 4),
              Text(
                _totalScanFiles > 0
                    ? 'Scanning $_filesScanned / $_totalScanFiles files…'
                    : 'Counting files…',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ],
            if (_inventoryResult != null) ...<Widget>[
              const SizedBox(height: 24),
              _buildScanSummaryCard(),
              const SizedBox(height: 16),
              _buildScanScopeCard(),
            ],
            const SizedBox(height: 24),
            ..._buildResultWidgets(),
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
                    onPressed: (_isInventoryRunning || _isRunning)
                        ? null
                        : _addFolder,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Select Folder'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_isRunning || _inventoryResult == null)
                        ? null
                        : _buildManifest,
                    icon: const Icon(Icons.search),
                    label: Text(_isRunning ? 'Scanning…' : 'Build Manifest'),
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
                  onChanged: (_isInventoryRunning || _isRunning)
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
  final Color? color;

  const _SummaryItem({required this.label, required this.value, this.color});

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
              color: color,
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

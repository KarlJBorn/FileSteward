import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'consolidate_models.dart';
import 'consolidate_service.dart';
import 'manifest_models.dart';
import 'manifest_service.dart';

// ---------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------

enum _Step {
  select,   // 0 — choose source folders + target
  filter,   // 1 — extension filter (inventory)
  scope,    // 2 — scope review before scan
  scan,     // 3 — running unified scan (auto)
  review,   // 4 — review duplicate groups
  build,    // 5 — executing copy (auto)
  done,     // 6 — result
}

const _stepLabels = [
  'Select',
  'Filter',
  'Scope',
  'Scan',
  'Review',
  'Build',
  'Done',
];

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class ConsolidateScreen extends StatefulWidget {
  const ConsolidateScreen({super.key});

  @override
  State<ConsolidateScreen> createState() => _ConsolidateScreenState();
}

class _ConsolidateScreenState extends State<ConsolidateScreen> {
  final _service = const ConsolidateService();
  final _manifestService = const ManifestService();

  _Step _step = _Step.select;

  // Step 1 — Select
  final List<String> _folders = [];
  String? _targetParentPath;
  final TextEditingController _targetNameController = TextEditingController();
  bool _targetManuallySet = false;

  // Step 2 — Filter (inventory)
  Map<String, InventoryResult?> _inventories = {};
  bool _isLoadingInventories = false;
  Set<String> _includeExtensions = {};

  // Step 3 — Scope (no async work here, just confirmation)

  // Step 4 — Scan
  int _scanFilesCount = 0;
  String _scanningSource = '';
  DateTime? _scanStartTime;
  Duration _elapsed = Duration.zero;
  Timer? _elapsedTimer;
  String? _sessionId;

  // Step 5 — Review
  ConsolidateUnifiedScanComplete? _scanResult;
  // Map: group index → chosen absolute path (starts at suggestedKeep)
  late Map<int, String> _keeperDecisions;

  // Step 6 — Build
  int _buildDone = 0;
  int _buildTotal = 0;

  // Step 7 — Done
  int _filesCopied = 0;
  String? _targetPath;

  // Shared
  String? _errorMessage;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _targetNameController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Helpers — target path
  // ---------------------------------------------------------------------------

  String? get _resolvedTargetPath {
    final parent = _targetParentPath;
    final name = _targetNameController.text.trim();
    if (parent == null || name.isEmpty) return null;
    return '$parent/$name';
  }

  void _autoPopulateTarget(String folderPath) {
    if (_targetManuallySet) return;
    final parts = folderPath.split('/');
    final parent =
        parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '/';
    setState(() {
      _targetParentPath = parent;
      _targetNameController.text = '${parts.last}_consolidated';
    });
  }

  bool _isDangerousPath(String path) {
    final parts =
        path.replaceAll(RegExp(r'/$'), '').split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length <= 1) return true;
    if (parts.length == 2 && parts[0] == 'Volumes') return true;
    const systemDirs = {
      'System', 'Library', 'Applications', 'bin', 'sbin',
      'usr', 'etc', 'var', 'private', 'cores', 'opt',
    };
    if (parts.length == 1 && systemDirs.contains(parts[0])) return true;
    return false;
  }

  String _leafName(String path) => path.split('/').last;

  String _shortPath(String path) {
    final parts = path.split('/');
    return parts.length > 3
        ? '…/${parts.sublist(parts.length - 2).join('/')}'
        : path;
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatElapsed(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Color _folderColor(int index) {
    const colors = [
      Color(0xFF0E70C0),
      Color(0xFF0A7764),
      Color(0xFF7B3FB5),
      Color(0xFFB85C00),
      Color(0xFF1B6B3A),
      Color(0xFF8B3A3A),
    ];
    return colors[index % colors.length];
  }

  // ---------------------------------------------------------------------------
  // Timer
  // ---------------------------------------------------------------------------

  void _startTimer() {
    _scanStartTime = DateTime.now();
    _elapsed = Duration.zero;
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_scanStartTime != null && mounted) {
        setState(() => _elapsed = DateTime.now().difference(_scanStartTime!));
      }
    });
  }

  void _stopTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Step transitions
  // ---------------------------------------------------------------------------

  // Step 0 → 1: load inventories for all selected folders
  Future<void> _advanceToFilter() async {
    setState(() {
      _isLoadingInventories = true;
      _step = _Step.filter;
      _inventories = {};
      _includeExtensions = {};
      _errorMessage = null;
    });

    final results = <String, InventoryResult?>{};
    for (final folder in _folders) {
      try {
        final inv = await _manifestService.buildInventory(folder);
        results[folder] = inv;
      } catch (_) {
        results[folder] = null;
      }
    }

    if (mounted) {
      setState(() {
        _inventories = results;
        _isLoadingInventories = false;
      });
    }
  }

  // Step 1 → 2
  void _advanceToScope() => setState(() => _step = _Step.scope);

  // Step 2 → 3: start scan
  Future<void> _startScan() async {
    setState(() {
      _step = _Step.scan;
      _scanFilesCount = 0;
      _scanningSource = '';
      _errorMessage = null;
    });
    _startTimer();

    final extensions = _includeExtensions.isEmpty
        ? <String>[]
        : _includeExtensions.toList();

    ConsolidateUnifiedScanComplete? scanComplete;

    await for (final event in _service.unifiedScan(
      sessionId: '',
      folders: _folders,
      target: _resolvedTargetPath ?? '',
      includeExtensions: extensions,
    )) {
      switch (event) {
        case ConsolidateProgress(:final source, :final filesScanned):
          setState(() {
            _scanFilesCount = filesScanned;
            _scanningSource = source;
          });
        case ConsolidateError(:final message):
          _stopTimer();
          setState(() {
            _errorMessage = message;
            _step = _Step.scope;
          });
          return;
        default:
          if (event is ConsolidateUnifiedScanComplete) {
            scanComplete = event;
          }
          break;
      }
    }

    _stopTimer();

    if (scanComplete == null) {
      setState(() {
        _errorMessage = 'Scan did not complete.';
        _step = _Step.scope;
      });
      return;
    }

    // Initialise keeper decisions to suggested_keep for each group.
    _keeperDecisions = {
      for (int i = 0; i < scanComplete.duplicateGroups.length; i++)
        i: scanComplete.duplicateGroups[i].suggestedKeep,
    };

    setState(() {
      _sessionId = scanComplete!.sessionId;
      _scanResult = scanComplete;
      _step = _Step.review;
    });
  }

  // Step 4 → 5: start build
  Future<void> _startBuild() async {
    final result = _scanResult!;
    final target = _resolvedTargetPath!;

    if (Directory(target).existsSync()) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Output folder already exists'),
          content: Text(
            '"${_leafName(target)}" already exists.\n\n'
            'Any files with matching paths will be overwritten. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange[700],
                foregroundColor: Colors.white,
              ),
              child: const Text('Overwrite'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    // Collect approved files: unique files + kept copies from dupe groups.
    // Organise by source folder → relative paths.
    final byFolder = <String, List<String>>{};

    for (final uf in result.uniqueFiles) {
      byFolder.putIfAbsent(uf.folder, () => []).add(uf.relativePath);
    }

    for (int i = 0; i < result.duplicateGroups.length; i++) {
      final absKeep = _keeperDecisions[i] ?? result.duplicateGroups[i].suggestedKeep;
      // Parse folder + relative_path from the absolute keeper path.
      final (String folder, String rel) = _splitAbsPath(absKeep, _folders);
      byFolder.putIfAbsent(folder, () => []).add(rel);
    }

    final buildFolders = byFolder.entries
        .map((e) => V2FolderBuildCmd(folder: e.key, relativePaths: e.value))
        .toList();

    final total = byFolder.values.fold(0, (s, l) => s + l.length);

    setState(() {
      _step = _Step.build;
      _buildTotal = total;
      _buildDone = 0;
      _targetPath = target;
      _errorMessage = null;
    });
    _startTimer();

    int filesCopied = 0;

    await for (final event in _service.v2Build(
      sessionId: _sessionId ?? '',
      target: target,
      folders: buildFolders,
    )) {
      switch (event) {
        case ConsolidateProgress(:final filesScanned):
          setState(() => _buildDone = filesScanned);
        case ConsolidateBuildComplete(filesCopied: final n):
          filesCopied = n;
        case ConsolidateError(:final message):
          _stopTimer();
          setState(() {
            _errorMessage = message;
            _step = _Step.review;
          });
          return;
        default:
          break;
      }
    }

    _stopTimer();
    setState(() {
      _filesCopied = filesCopied;
      _step = _Step.done;
    });
  }

  /// Given an absolute path and the list of source folders, extract the
  /// (folder, relative_path) pair by finding which folder is a prefix.
  (String, String) _splitAbsPath(String absPath, List<String> folders) {
    for (final folder in folders) {
      final prefix = folder.endsWith('/') ? folder : '$folder/';
      if (absPath.startsWith(prefix)) {
        return (folder, absPath.substring(prefix.length));
      }
    }
    // Fallback: treat entire path as relative to first folder.
    return (folders.isNotEmpty ? folders.first : '', absPath);
  }

  // ---------------------------------------------------------------------------
  // Step-indicator widget
  // ---------------------------------------------------------------------------

  Widget _buildStepIndicator() {
    final currentIndex = _Step.values.indexOf(_step);
    return Container(
      color: Colors.grey[50],
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: Row(
        children: List.generate(_stepLabels.length * 2 - 1, (i) {
          if (i.isOdd) {
            // Connector line
            final leftStepIdx = i ~/ 2;
            final isCompleted = leftStepIdx < currentIndex;
            return Expanded(
              child: Container(
                height: 2,
                color: isCompleted ? const Color(0xFF0E70C0) : Colors.grey[300],
              ),
            );
          }
          final idx = i ~/ 2;
          final isCompleted = idx < currentIndex;
          final isCurrent = idx == currentIndex;
          return _StepDot(
            index: idx,
            label: _stepLabels[idx],
            isCompleted: isCompleted,
            isCurrent: isCurrent,
          );
        }),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Root build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isAutoStep =
        _step == _Step.scan || _step == _Step.build;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Consolidate'),
        leading: (!isAutoStep && _step != _Step.select && _step != _Step.done)
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _handleBack,
                tooltip: 'Back',
              )
            : const SizedBox.shrink(),
      ),
      body: Column(
        children: [
          _buildStepIndicator(),
          const Divider(height: 1),
          Expanded(child: _buildCurrentStep()),
        ],
      ),
    );
  }

  void _handleBack() {
    switch (_step) {
      case _Step.filter:
        setState(() => _step = _Step.select);
      case _Step.scope:
        setState(() => _step = _Step.filter);
      case _Step.review:
        // Allow going back to scope (will need to re-scan to change anything).
        setState(() => _step = _Step.scope);
      default:
        break;
    }
  }

  Widget _buildCurrentStep() {
    return switch (_step) {
      _Step.select => _buildSelectStep(),
      _Step.filter => _buildFilterStep(),
      _Step.scope => _buildScopeStep(),
      _Step.scan => _buildScanStep(),
      _Step.review => _buildReviewStep(),
      _Step.build => _buildBuildStep(),
      _Step.done => _buildDoneStep(),
    };
  }

  // ---------------------------------------------------------------------------
  // Step 1 — Select
  // ---------------------------------------------------------------------------

  Widget _buildSelectStep() {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_errorMessage != null) _ErrorBanner(message: _errorMessage!),
                _SectionHeader(
                  title: 'Source Folders',
                  subtitle:
                      'Add two or more folders to consolidate. All are treated equally — no primary or secondary.',
                ),
                const SizedBox(height: 12),
                ..._folders.asMap().entries.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _SourceTile(
                        path: e.value,
                        label: 'Folder ${e.key + 1}',
                        color: _folderColor(e.key),
                        onRemove: () => setState(() => _folders.removeAt(e.key)),
                      ),
                    )),
                OutlinedButton.icon(
                  onPressed: _addFolder,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Folder…'),
                ),
                const SizedBox(height: 24),
                _SectionHeader(
                  title: 'Output Folder',
                  subtitle: 'Where the consolidated folder will be created.',
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickTargetParent,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: Text(
                          _targetParentPath != null
                              ? _leafName(_targetParentPath!)
                              : 'Choose Location…',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _targetNameController,
                        decoration: const InputDecoration(
                          labelText: 'Folder name',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (_) =>
                            setState(() => _targetManuallySet = true),
                      ),
                    ),
                  ],
                ),
                if (_resolvedTargetPath != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _resolvedTargetPath!,
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
        _BottomBar(
          child: ElevatedButton.icon(
            onPressed: (_folders.length >= 2 && _resolvedTargetPath != null)
                ? _advanceToFilter
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0E70C0),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Continue'),
          ),
        ),
      ],
    );
  }

  Future<void> _addFolder() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return;
    if (_isDangerousPath(path)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Please select a specific folder, not a whole drive or volume root.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }
    if (_folders.contains(path)) return;
    setState(() => _folders.add(path));
    if (_folders.length == 1) _autoPopulateTarget(path);
  }

  Future<void> _pickTargetParent() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return;
    setState(() {
      _targetParentPath = path;
      _targetManuallySet = true;
    });
  }

  // ---------------------------------------------------------------------------
  // Step 2 — Filter
  // ---------------------------------------------------------------------------

  Widget _buildFilterStep() {
    if (_isLoadingInventories) {
      return const Center(child: CircularProgressIndicator());
    }

    // Merge all extension stats across all folders.
    final merged = <String, int>{};
    for (final inv in _inventories.values) {
      if (inv == null) continue;
      for (final stat in inv.extensions) {
        merged[stat.extension] =
            (merged[stat.extension] ?? 0) + stat.count;
      }
    }
    final sortedExts = merged.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final maxCount =
        sortedExts.isEmpty ? 1 : sortedExts.map((e) => e.value).reduce((a, b) => a > b ? a : b);

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SectionHeader(
                  title: 'Folder and File Filter',
                  subtitle:
                      'Choose which file types to include in the scan. Leave all unchecked to include everything.',
                ),
                const SizedBox(height: 12),
                if (sortedExts.isEmpty)
                  Text(
                    'Could not load file type information.',
                    style: TextStyle(color: Colors.grey[500]),
                  )
                else ...[
                  // Select all / none
                  Row(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: Checkbox(
                          tristate: true,
                          value: _includeExtensions.isEmpty
                              ? false
                              : _includeExtensions.length == merged.length
                                  ? true
                                  : null,
                          onChanged: (_) => setState(() {
                            if (_includeExtensions.length == merged.length) {
                              _includeExtensions = {};
                            } else {
                              _includeExtensions = merged.keys.toSet();
                            }
                          }),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text('All file types',
                          style: TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(width: 8),
                      Text(
                        _includeExtensions.isEmpty ? '(all included)' : '',
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                  const Divider(height: 16),
                  ...sortedExts.map((entry) {
                    final isSelected =
                        _includeExtensions.contains(entry.key);
                    final label = entry.key.isEmpty
                        ? '(no extension)'
                        : entry.key;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: Checkbox(
                              value: isSelected,
                              onChanged: (checked) => setState(() {
                                if (checked == true) {
                                  _includeExtensions.add(entry.key);
                                } else {
                                  _includeExtensions.remove(entry.key);
                                }
                              }),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 80,
                            child: Text(
                              label,
                              style: const TextStyle(fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: LinearProgressIndicator(
                              value: entry.value / maxCount,
                              backgroundColor: Colors.grey[200],
                              color: isSelected || _includeExtensions.isEmpty
                                  ? const Color(0xFF0E70C0)
                                  : Colors.grey[300],
                              minHeight: 6,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${entry.value}',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
        ),
        _BottomBar(
          child: ElevatedButton.icon(
            onPressed: _advanceToScope,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0E70C0),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Continue'),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Step 3 — Scope Review
  // ---------------------------------------------------------------------------

  Widget _buildScopeStep() {
    // Estimate total files from inventories.
    int estimatedFiles = 0;
    if (_includeExtensions.isEmpty) {
      for (final inv in _inventories.values) {
        if (inv != null) estimatedFiles += inv.totalFiles;
      }
    } else {
      for (final inv in _inventories.values) {
        if (inv == null) continue;
        for (final stat in inv.extensions) {
          if (_includeExtensions.contains(stat.extension)) {
            estimatedFiles += stat.count;
          }
        }
      }
    }

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_errorMessage != null)
                  _ErrorBanner(message: _errorMessage!),
                _SectionHeader(
                  title: 'Scope Review',
                  subtitle:
                      'Confirm what will be scanned before starting.',
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${_folders.length} folders',
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        ..._folders.asMap().entries.map((e) => Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 3),
                              child: Row(
                                children: [
                                  Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      color: _folderColor(e.key),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _shortPath(e.value),
                                      style: const TextStyle(fontSize: 13),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            )),
                        const Divider(height: 24),
                        Row(
                          children: [
                            _ScopeChip(
                              label: 'Files',
                              value: estimatedFiles > 0
                                  ? '~$estimatedFiles'
                                  : '—',
                            ),
                            const SizedBox(width: 16),
                            _ScopeChip(
                              label: 'Types',
                              value: _includeExtensions.isEmpty
                                  ? 'All'
                                  : '${_includeExtensions.length} selected',
                            ),
                          ],
                        ),
                        const Divider(height: 24),
                        Text(
                          'Output: ${_resolvedTargetPath ?? '—'}',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey[600]),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        _BottomBar(
          child: ElevatedButton.icon(
            onPressed: _startScan,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0E70C0),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.search),
            label: const Text('Start Scan'),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Step 4 — Scan (auto)
  // ---------------------------------------------------------------------------

  Widget _buildScanStep() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                const Text('Scanning…',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                Text(
                  _formatElapsed(_elapsed),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w300,
                    color: Colors.grey[600],
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_scanningSource.isNotEmpty && _scanningSource != 'unified')
              Text(
                _shortPath(_scanningSource),
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            if (_scanFilesCount > 0)
              Text(
                '$_scanFilesCount files hashed',
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Step 5 — Review
  // ---------------------------------------------------------------------------

  Widget _buildReviewStep() {
    final result = _scanResult;
    if (result == null) return const SizedBox.shrink();

    final autoResolved =
        result.duplicateGroups.where((g) => !g.ambiguous).length;
    final ambiguous =
        result.duplicateGroups.where((g) => g.ambiguous).length;

    // Potential savings: for each duplicate group, sum (copies-1) * size.
    int savingsBytes = 0;
    for (final g in result.duplicateGroups) {
      savingsBytes += g.sizeBytes * (g.paths.length - 1);
    }

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Summary card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 24,
                      runSpacing: 12,
                      alignment: WrapAlignment.spaceEvenly,
                      children: [
                        _SummaryChip(
                          label: 'Total',
                          value: '${result.totalFiles}',
                        ),
                        _SummaryChip(
                          label: 'Unique',
                          value: '${result.uniqueFiles.length}',
                          color: Colors.green[700],
                        ),
                        _SummaryChip(
                          label: 'Dup groups',
                          value: '${result.duplicateGroups.length}',
                          color: Colors.orange[700],
                        ),
                        _SummaryChip(
                          label: 'Auto-resolved',
                          value: '$autoResolved',
                          color: Colors.blue[700],
                        ),
                        if (ambiguous > 0)
                          _SummaryChip(
                            label: 'Need review',
                            value: '$ambiguous',
                            color: Colors.red[700],
                          ),
                        if (savingsBytes > 0)
                          _SummaryChip(
                            label: 'Savings',
                            value: _formatSize(savingsBytes),
                            color: Colors.green[800],
                          ),
                      ],
                    ),
                  ),
                ),
                if (result.duplicateGroups.isEmpty) ...[
                  const SizedBox(height: 24),
                  Center(
                    child: Column(
                      children: [
                        Icon(Icons.check_circle_outline,
                            size: 56, color: Colors.green[600]),
                        const SizedBox(height: 12),
                        const Text('No duplicates found.',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(
                          'All ${result.totalFiles} files are unique.',
                          style: TextStyle(
                              fontSize: 13, color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  // Ambiguous groups — require user decision
                  if (ambiguous > 0) ...[
                    const SizedBox(height: 20),
                    _SectionHeader(
                      title: 'Needs Review ($ambiguous)',
                      subtitle:
                          'The ranker could not automatically pick a winner. Choose which copy to keep.',
                    ),
                    const SizedBox(height: 8),
                    ...result.duplicateGroups.asMap().entries
                        .where((e) => e.value.ambiguous)
                        .map((e) => _buildGroupCard(e.key, e.value)),
                  ],
                  // Auto-resolved groups — collapsed summary
                  if (autoResolved > 0) ...[
                    const SizedBox(height: 20),
                    _SectionHeader(
                      title: 'Auto-Resolved ($autoResolved)',
                      subtitle:
                          'The ranker selected the best copy. Expand to review.',
                    ),
                    const SizedBox(height: 8),
                    ...result.duplicateGroups.asMap().entries
                        .where((e) => !e.value.ambiguous)
                        .map((e) => _buildGroupCard(e.key, e.value)),
                  ],
                ],
              ],
            ),
          ),
        ),
        _BottomBar(
          child: ElevatedButton.icon(
            onPressed: _startBuild,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal[700],
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.build),
            label: Text(ambiguous > 0
                ? 'Build with my decisions'
                : 'Build consolidated folder'),
          ),
        ),
      ],
    );
  }

  Widget _buildGroupCard(int groupIdx, UnifiedDuplicateGroup group) {
    final chosenKeep = _keeperDecisions[groupIdx] ?? group.suggestedKeep;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        tilePadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        title: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: group.ambiguous
                    ? Colors.red[50]
                    : Colors.blue[50],
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                    color: group.ambiguous
                        ? Colors.red[300]!
                        : Colors.blue[300]!),
              ),
              child: Text(
                group.ambiguous ? 'Review needed' : 'Auto',
                style: TextStyle(
                    fontSize: 11,
                    color: group.ambiguous
                        ? Colors.red[700]
                        : Colors.blue[700]),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _leafName(group.paths.first),
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              _formatSize(group.sizeBytes),
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
        initiallyExpanded: group.ambiguous,
        children: group.paths.map((absPath) {
          final isChosen = absPath == chosenKeep;
          return InkWell(
            onTap: () => setState(() => _keeperDecisions[groupIdx] = absPath),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Radio<String>(
                    value: absPath,
                    groupValue: chosenKeep,
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _keeperDecisions[groupIdx] = val);
                      }
                    },
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _shortPath(absPath),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isChosen
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (group.reasons.isNotEmpty && isChosen)
                          Text(
                            group.reasons.join(', '),
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey[500]),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Step 6 — Build (auto)
  // ---------------------------------------------------------------------------

  Widget _buildBuildStep() {
    final fraction =
        _buildTotal > 0 ? _buildDone / _buildTotal : null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                const Text('Building…',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600)),
                Text(
                  _formatElapsed(_elapsed),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w300,
                    color: Colors.grey[600],
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: fraction),
            const SizedBox(height: 8),
            Text(
              _buildTotal > 0
                  ? '$_buildDone / $_buildTotal files copied'
                  : 'Copying files…',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Step 7 — Done
  // ---------------------------------------------------------------------------

  Widget _buildDoneStep() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, size: 72, color: Colors.green[600]),
            const SizedBox(height: 20),
            const Text(
              'Done',
              style:
                  TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '$_filesCopied files copied',
              style:
                  TextStyle(fontSize: 16, color: Colors.grey[700]),
            ),
            if (_targetPath != null) ...[
              const SizedBox(height: 8),
              Text(
                _targetPath!,
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 32),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_targetPath != null)
                  OutlinedButton.icon(
                    onPressed: () =>
                        Process.run('open', [_targetPath!]),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Open Folder'),
                  ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _resetToStart,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0E70C0),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Consolidate Again'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _resetToStart() {
    setState(() {
      _step = _Step.select;
      _folders.clear();
      _targetParentPath = null;
      _targetNameController.clear();
      _targetManuallySet = false;
      _inventories = {};
      _includeExtensions = {};
      _scanResult = null;
      _sessionId = null;
      _filesCopied = 0;
      _targetPath = null;
      _errorMessage = null;
    });
  }
}

// ---------------------------------------------------------------------------
// Shared sub-widgets
// ---------------------------------------------------------------------------

class _StepDot extends StatelessWidget {
  final int index;
  final String label;
  final bool isCompleted;
  final bool isCurrent;

  const _StepDot({
    required this.index,
    required this.label,
    required this.isCompleted,
    required this.isCurrent,
  });

  @override
  Widget build(BuildContext context) {
    const activeColor = Color(0xFF0E70C0);
    final bg = isCompleted || isCurrent ? activeColor : Colors.grey[300]!;
    final fg = isCompleted || isCurrent ? Colors.white : Colors.grey[600]!;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Center(
            child: isCompleted
                ? const Icon(Icons.check, size: 16, color: Colors.white)
                : Text(
                    '${index + 1}',
                    style: TextStyle(
                        fontSize: 12, color: fg, fontWeight: FontWeight.bold),
                  ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: isCurrent ? activeColor : Colors.grey[500],
            fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionHeader({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style:
                const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(subtitle,
            style: TextStyle(fontSize: 13, color: Colors.grey[600])),
      ],
    );
  }
}

class _SourceTile extends StatelessWidget {
  final String path;
  final String label;
  final Color color;
  final VoidCallback onRemove;

  const _SourceTile({
    required this.path,
    required this.label,
    required this.color,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
        color: color.withValues(alpha: 0.04),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: color)),
              const SizedBox(height: 2),
              Text(
                path,
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: onRemove,
            tooltip: 'Remove',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            color: Colors.grey[500],
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final Widget child;

  const _BottomBar({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: Colors.grey[200]!)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [child],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;

  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red[200]!),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: Colors.red[700], size: 18),
          const SizedBox(width: 8),
          Expanded(
              child: Text(message,
                  style: TextStyle(color: Colors.red[800], fontSize: 13))),
        ],
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  final String label;
  final String value;

  const _ScopeChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label,
            style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _SummaryChip(
      {required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(fontSize: 12),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

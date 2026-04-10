import 'package:flutter/material.dart';

import 'consolidate_models.dart';
import 'consolidate_service.dart';

// ---------------------------------------------------------------------------
// ConsolidateScan2Screen — Screen 3
//
// Phase 3.1 — Hashing progress:
//   Deterministic progress bar ("Hashed X of Y files") driven by totalFiles
//   from Scan 1.
//
// Phase 3.2 — Review / decisions:
//   • Stats band (files to copy, duplicates removed, output size)
//   • Two-panel layout:
//       Left  — Source trees (read-only, one collapsible section per folder)
//       Right — Proposed target tree (color-coded: green=copy,
//               orange=duplicate skipped, amber=collision/ambiguity)
//   • Issues panel below trees — one card per collision (both files editable)
//     and one card per ambiguity; each card has a Dismiss button
//   • Build button blocked until all issue cards are dismissed
// ---------------------------------------------------------------------------

class ConsolidateScan2Screen extends StatefulWidget {
  const ConsolidateScan2Screen({
    super.key,
    required this.sourceFolders,
    required this.excludedExtensions,
    required this.excludedFolders,
    this.overriddenPaths = const [],
    required this.totalFiles,
    required this.service,
    required this.onProceed,
    required this.onBack,
  });

  final List<String> sourceFolders;
  final List<String> excludedExtensions;
  final List<String> excludedFolders;
  final List<String> overriddenPaths;

  /// Total file count from Scan 1 — used for deterministic progress bar.
  final int totalFiles;

  final ConsolidateService service;

  /// Called with the routing plan and any name overrides.
  /// [nameOverrides] maps '${sourceFolder}|${sourceRelativePath}' →
  /// full override target relative path.
  final void Function(
    ContentScanComplete result,
    Map<String, String> nameOverrides,
  ) onProceed;

  final VoidCallback onBack;

  @override
  State<ConsolidateScan2Screen> createState() =>
      _ConsolidateScan2ScreenState();
}

class _ConsolidateScan2ScreenState extends State<ConsolidateScan2Screen> {
  // ---------------------------------------------------------------------------
  // 3.1 — Scan state
  // ---------------------------------------------------------------------------

  bool _scanning = true;
  int _filesHashed = 0;
  String? _error;

  // ---------------------------------------------------------------------------
  // 3.2 — Review state
  // ---------------------------------------------------------------------------

  ContentScanComplete? _result;

  /// Files grouped by sourceFolder for the left (source) panel.
  final Map<String, List<RoutedFile>> _filesBySource = {};

  /// Files grouped by top-level target folder for the right (target) panel.
  final Map<String, List<RoutedFile>> _filesByTargetFolder = {};

  /// For each collision (keyed by targetRelativePath), the routing entry that
  /// "won" the path (action == 'copy', not in the renamed entries list).
  final Map<String, RoutedFile?> _collisionWinners = {};

  /// Name controllers keyed by '${sourceFolder}|${sourceRelativePath}'.
  /// Populated for both collision winners and renamed entries so the user can
  /// edit either file's target name.
  final Map<String, TextEditingController> _nameControllers = {};

  /// Set of dismissed issue IDs.
  /// Collision: 'collision|${targetRelativePath}'
  /// Ambiguity: 'ambiguity|$index'
  final Set<String> _dismissedIssues = {};

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _runScan();
  }

  @override
  void dispose() {
    for (final c in _nameControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Scan
  // ---------------------------------------------------------------------------

  void _runScan() {
    widget.service
        .contentScan(
          folders: widget.sourceFolders,
          excludedExtensions: widget.excludedExtensions,
          excludedFolders: widget.excludedFolders,
          overriddenPaths: widget.overriddenPaths,
        )
        .listen(
      (event) {
        if (!mounted) return;
        if (event is ConsolidateProgress) {
          setState(() => _filesHashed = event.filesScanned);
        } else if (event is ContentScanComplete) {
          _processResult(event);
          setState(() {
            _scanning = false;
            _result = event;
          });
        } else if (event is ConsolidateError) {
          setState(() {
            _scanning = false;
            _error = event.message;
          });
        }
      },
      onError: (e) {
        if (!mounted) return;
        setState(() {
          _scanning = false;
          _error = e.toString();
        });
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Result processing
  // ---------------------------------------------------------------------------

  void _processResult(ContentScanComplete result) {
    // Group files by source folder.
    for (final rf in result.routing) {
      (_filesBySource[rf.sourceFolder] ??= []).add(rf);
    }

    // Group files by top-level target folder.
    for (final rf in result.routing) {
      final parts = rf.targetRelativePath.split('/');
      final folder = parts.length > 1 ? parts.first : '(root)';
      (_filesByTargetFolder[folder] ??= []).add(rf);
    }

    // Build a quick lookup: '${sourceFolder}|${sourceRelPath}' → RoutedFile.
    final routingIndex = <String, RoutedFile>{};
    for (final rf in result.routing) {
      routingIndex['${rf.sourceFolder}|${rf.sourceRelativePath}'] = rf;
    }

    // Find the winner (non-renamed copy) for each collision and initialise
    // name controllers for both the winner and each renamed entry.
    for (final collision in result.collisions) {
      final entryKeys = collision.entries
          .map((e) => '${e.sourceFolder}|${e.sourceRelativePath}')
          .toSet();

      // Winner = a 'copy' entry whose targetRelativePath equals the collision
      // target and that is NOT one of the renamed entries.
      final winner = result.routing
          .where((rf) =>
              rf.targetRelativePath == collision.targetRelativePath &&
              rf.action == 'copy' &&
              !entryKeys.contains('${rf.sourceFolder}|${rf.sourceRelativePath}'))
          .firstOrNull;
      _collisionWinners[collision.targetRelativePath] = winner;

      // Controller for the winner (starts with its current full target path).
      if (winner != null) {
        final key = '${winner.sourceFolder}|${winner.sourceRelativePath}';
        _nameControllers[key] ??=
            TextEditingController(text: winner.targetRelativePath);
      }

      // Controller for each renamed entry (starts with its full target path).
      for (final entry in collision.entries) {
        final key = '${entry.sourceFolder}|${entry.sourceRelativePath}';
        final rf = routingIndex[key];
        _nameControllers[key] ??= TextEditingController(
          text: rf?.targetRelativePath ?? entry.renamedTo,
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  String _folderName(String path) => path.split('/').last;

  int get _totalIssues =>
      (_result?.collisions.length ?? 0) + (_result?.ambiguities.length ?? 0);

  bool get _allIssuesDismissed => _dismissedIssues.length >= _totalIssues;

  bool _isCollisionFile(String sourceFolder, String sourceRelPath) {
    final result = _result;
    if (result == null) return false;
    for (final col in result.collisions) {
      for (final e in col.entries) {
        if (e.sourceFolder == sourceFolder &&
            e.sourceRelativePath == sourceRelPath) return true;
      }
      final winner = _collisionWinners[col.targetRelativePath];
      if (winner != null &&
          winner.sourceFolder == sourceFolder &&
          winner.sourceRelativePath == sourceRelPath) return true;
    }
    return false;
  }

  void _proceed() {
    final result = _result;
    if (result == null) return;
    final overrides = <String, String>{};
    _nameControllers.forEach((key, ctrl) {
      if (ctrl.text.isNotEmpty) overrides[key] = ctrl.text;
    });
    widget.onProceed(result, overrides);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(),
        if (_scanning) Expanded(child: _buildScanningView()),
        if (_error != null) Expanded(child: _buildErrorView()),
        if (!_scanning && _result != null) ...[
          _buildStatsBar(_result!),
          Expanded(child: _buildReviewBody(_result!)),
          _buildBottomBar(_result!),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Header
  // ---------------------------------------------------------------------------

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
                tooltip: 'Back to Filter',
              ),
              const SizedBox(width: 8),
              Text(
                _scanning ? 'Step 3: Review — Hashing files…' : 'Step 3: Review',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const Divider(height: 24),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 3.1 — Scanning view
  // ---------------------------------------------------------------------------

  Widget _buildScanningView() {
    final total = widget.totalFiles;
    final progress = total > 0 ? (_filesHashed / total).clamp(0.0, 1.0) : null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 16),
            Text(
              total > 0
                  ? 'Hashed $_filesHashed of $total files'
                  : 'Hashing files…',
              style: const TextStyle(fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Error view
  // ---------------------------------------------------------------------------

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 3.2 — Stats band
  // ---------------------------------------------------------------------------

  Widget _buildStatsBar(ContentScanComplete result) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStat('To Copy', '${result.filesToCopy}', Colors.green.shade700),
          _buildStat('Duplicates', '${result.duplicatesSkipped}',
              Colors.orange.shade700),
          _buildStat('Output Size', _formatBytes(result.totalOutputSizeBytes),
              Colors.blue.shade700),
          _buildStat(
            'Issues',
            '$_totalIssues',
            _totalIssues == 0 ? Colors.green.shade700 : Colors.amber.shade800,
          ),
        ],
      ),
    );
  }

  Widget _buildStat(String label, String value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(fontSize: 11, color: Colors.black54)),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 3.2 — Review body (trees + issues panel)
  // ---------------------------------------------------------------------------

  Widget _buildReviewBody(ContentScanComplete result) {
    final hasIssues = _totalIssues > 0;
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildSourcePanel()),
              VerticalDivider(width: 1, color: Colors.grey.shade200),
              Expanded(child: _buildTargetPanel(result)),
            ],
          ),
        ),
        if (hasIssues) ...[
          Divider(height: 1, color: Colors.grey.shade200),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: _buildIssuesPanel(result),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Left panel — Source trees
  // ---------------------------------------------------------------------------

  Widget _buildSourcePanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader('Sources', Icons.folder_copy_outlined),
        Expanded(
          child: ListView(
            children: widget.sourceFolders.asMap().entries.map((entry) {
              final i = entry.key;
              final folder = entry.value;
              final files = _filesBySource[folder] ?? [];
              return _SourceFolderSection(
                folderName: _folderName(folder),
                files: files,
                color: _folderColor(i),
                isCollisionFile: _isCollisionFile,
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Right panel — Proposed target tree
  // ---------------------------------------------------------------------------

  Widget _buildTargetPanel(ContentScanComplete result) {
    // Collect target paths involved in collisions for ⚠ marking.
    final issueTargetPaths = <String>{};
    for (final col in result.collisions) {
      issueTargetPaths.add(col.targetRelativePath);
      for (final e in col.entries) {
        for (final rf in result.routing) {
          if (rf.sourceFolder == e.sourceFolder &&
              rf.sourceRelativePath == e.sourceRelativePath) {
            issueTargetPaths.add(rf.targetRelativePath);
            break;
          }
        }
      }
    }

    final sortedEntries = _filesByTargetFolder.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader('Proposed Output', Icons.folder_outlined),
        Expanded(
          child: ListView(
            children: sortedEntries
                .map((entry) => _TargetFolderSection(
                      folderName: entry.key,
                      files: entry.value,
                      issueTargetPaths: issueTargetPaths,
                    ))
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildPanelHeader(String title, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 6),
          Text(title,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade700)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Issues panel
  // ---------------------------------------------------------------------------

  Widget _buildIssuesPanel(ContentScanComplete result) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
          decoration: BoxDecoration(
            color: Colors.amber.shade50,
            border: Border(bottom: BorderSide(color: Colors.amber.shade100)),
          ),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 15, color: Colors.amber.shade800),
              const SizedBox(width: 6),
              Text(
                '$_totalIssues issue${_totalIssues == 1 ? '' : 's'} — '
                'dismiss all to enable Build',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.amber.shade900),
              ),
              const Spacer(),
              Text(
                '${_dismissedIssues.length} / $_totalIssues dismissed',
                style: TextStyle(fontSize: 11, color: Colors.amber.shade800),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              ...result.collisions.asMap().entries.map((entry) {
                final id = 'collision|${entry.value.targetRelativePath}';
                return _buildCollisionCard(
                  collision: entry.value,
                  id: id,
                  dismissed: _dismissedIssues.contains(id),
                );
              }),
              ...result.ambiguities.asMap().entries.map((entry) {
                final id = 'ambiguity|${entry.key}';
                return _buildAmbiguityCard(
                  ambiguity: entry.value,
                  id: id,
                  dismissed: _dismissedIssues.contains(id),
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCollisionCard({
    required FilenameCollision collision,
    required String id,
    required bool dismissed,
  }) {
    final winner = _collisionWinners[collision.targetRelativePath];

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
            color: dismissed ? Colors.grey.shade200 : Colors.orange.shade200),
      ),
      color: dismissed ? Colors.grey.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Card header.
            Row(
              children: [
                Icon(Icons.drive_file_rename_outline,
                    size: 15,
                    color: dismissed
                        ? Colors.grey
                        : Colors.orange.shade700),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Name conflict: ${collision.targetRelativePath}',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: dismissed ? Colors.grey : null),
                  ),
                ),
                TextButton(
                  onPressed: dismissed
                      ? () => setState(
                          () => _dismissedIssues.remove(id))
                      : () => setState(() => _dismissedIssues.add(id)),
                  child: Text(dismissed ? 'Reopen' : 'Dismiss'),
                ),
              ],
            ),
            if (!dismissed) ...[
              const SizedBox(height: 10),
              const Text(
                'Two files have different content but would share the same '
                'output path. Edit either name to resolve.',
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
              const SizedBox(height: 10),
              // Winner row.
              if (winner != null)
                _buildEditableFileRow(
                  sourceFolder: winner.sourceFolder,
                  sourceRelPath: winner.sourceRelativePath,
                  label: 'Kept as',
                ),
              // Entry rows.
              ...collision.entries.map(
                (entry) => _buildEditableFileRow(
                  sourceFolder: entry.sourceFolder,
                  sourceRelPath: entry.sourceRelativePath,
                  label: 'Renamed to',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEditableFileRow({
    required String sourceFolder,
    required String sourceRelPath,
    required String label,
  }) {
    final key = '$sourceFolder|$sourceRelPath';
    final ctrl = _nameControllers[key];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.subdirectory_arrow_right,
              size: 14, color: Colors.black38),
          const SizedBox(width: 4),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _folderName(sourceFolder),
                  style: const TextStyle(fontSize: 10, color: Colors.black45),
                ),
                Text(sourceRelPath,
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.black38)),
          ),
          Expanded(
            flex: 2,
            child: ctrl != null
                ? TextField(
                    controller: ctrl,
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4)),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildAmbiguityCard({
    required ContentScanAmbiguity ambiguity,
    required String id,
    required bool dismissed,
  }) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
            color: dismissed ? Colors.grey.shade200 : Colors.amber.shade200),
      ),
      color: dismissed ? Colors.grey.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline,
                    size: 15,
                    color:
                        dismissed ? Colors.grey : Colors.amber.shade800),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    ambiguity.description,
                    style: TextStyle(
                        fontSize: 13,
                        color: dismissed ? Colors.grey : null),
                  ),
                ),
                TextButton(
                  onPressed: dismissed
                      ? () => setState(
                          () => _dismissedIssues.remove(id))
                      : () => setState(() => _dismissedIssues.add(id)),
                  child: Text(dismissed ? 'Reopen' : 'Dismiss'),
                ),
              ],
            ),
            if (!dismissed && ambiguity.files.isNotEmpty) ...[
              const SizedBox(height: 6),
              ...ambiguity.files.take(4).map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(left: 22, bottom: 2),
                      child: Text(f,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.black54),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ),
              if (ambiguity.files.length > 4)
                Padding(
                  padding: const EdgeInsets.only(left: 22),
                  child: Text(
                    '… and ${ambiguity.files.length - 4} more',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.black45),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Bottom bar
  // ---------------------------------------------------------------------------

  Widget _buildBottomBar(ContentScanComplete result) {
    final canBuild = _allIssuesDismissed;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              canBuild
                  ? '${result.filesToCopy} files to copy · '
                      '${_formatBytes(result.totalOutputSizeBytes)}'
                  : '${_totalIssues - _dismissedIssues.length} issue'
                      '${(_totalIssues - _dismissedIssues.length) == 1 ? '' : 's'} '
                      'remaining — dismiss all to build',
              style: TextStyle(
                  fontSize: 13,
                  color: canBuild ? Colors.black54 : Colors.amber.shade800),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: canBuild ? _proceed : null,
            icon: const Icon(Icons.build_outlined, size: 18),
            label: const Text('Build'),
          ),
        ],
      ),
    );
  }

  Color _folderColor(int index) {
    const colors = [
      Color(0xFF0E70C0),
      Color(0xFF0A7764),
      Color(0xFF7B3FB5),
      Color(0xFFB85C00),
    ];
    return colors[index % colors.length];
  }
}

// ---------------------------------------------------------------------------
// _SourceFolderSection — collapsible section for one source in the left panel
// ---------------------------------------------------------------------------

class _SourceFolderSection extends StatefulWidget {
  const _SourceFolderSection({
    required this.folderName,
    required this.files,
    required this.color,
    required this.isCollisionFile,
  });

  final String folderName;
  final List<RoutedFile> files;
  final Color color;
  final bool Function(String sourceFolder, String sourceRelPath)
      isCollisionFile;

  @override
  State<_SourceFolderSection> createState() => _SourceFolderSectionState();
}

class _SourceFolderSectionState extends State<_SourceFolderSection> {
  bool _expanded = true;

  static const _maxShown = 200;

  Color _dotColor(RoutedFile rf) {
    if (widget.isCollisionFile(rf.sourceFolder, rf.sourceRelativePath)) {
      return Colors.amber.shade700;
    }
    return switch (rf.action) {
      'skip_duplicate' => Colors.orange.shade400,
      _ => Colors.green.shade500,
    };
  }

  @override
  Widget build(BuildContext context) {
    final shown = widget.files.take(_maxShown).toList();
    final overflow = widget.files.length - shown.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header (tap to collapse).
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18,
                  color: widget.color,
                ),
                const SizedBox(width: 4),
                Icon(Icons.folder, size: 16, color: widget.color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.folderName,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: widget.color),
                  ),
                ),
                Text(
                  '${widget.files.length} files',
                  style:
                      const TextStyle(fontSize: 11, color: Colors.black45),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          ...shown.map(
            (rf) => Padding(
              padding: const EdgeInsets.only(left: 38, right: 16, bottom: 1),
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 6, top: 1),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _dotColor(rf),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      rf.sourceRelativePath,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.black54),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (overflow > 0)
            Padding(
              padding: const EdgeInsets.only(left: 50, bottom: 4),
              child: Text(
                '… and $overflow more',
                style: const TextStyle(
                    fontSize: 11, color: Colors.black38),
              ),
            ),
          Divider(height: 1, color: Colors.grey.shade100),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _TargetFolderSection — collapsible section in the right (target) panel
// ---------------------------------------------------------------------------

class _TargetFolderSection extends StatefulWidget {
  const _TargetFolderSection({
    required this.folderName,
    required this.files,
    required this.issueTargetPaths,
  });

  final String folderName;
  final List<RoutedFile> files;
  final Set<String> issueTargetPaths;

  @override
  State<_TargetFolderSection> createState() => _TargetFolderSectionState();
}

class _TargetFolderSectionState extends State<_TargetFolderSection> {
  bool _expanded = true;

  static const _maxShown = 200;

  Color _dotColor(RoutedFile rf) {
    if (widget.issueTargetPaths.contains(rf.targetRelativePath)) {
      return Colors.amber.shade700;
    }
    return switch (rf.action) {
      'skip_duplicate' => Colors.orange.shade400,
      _ => Colors.green.shade500,
    };
  }

  IconData _dotIcon(RoutedFile rf) {
    if (widget.issueTargetPaths.contains(rf.targetRelativePath)) {
      return Icons.warning_amber_rounded;
    }
    return Icons.circle;
  }

  @override
  Widget build(BuildContext context) {
    final shown = widget.files.take(_maxShown).toList();
    final overflow = widget.files.length - shown.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18,
                  color: Colors.grey.shade600,
                ),
                const SizedBox(width: 4),
                Icon(Icons.folder_outlined,
                    size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.folderName,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${widget.files.length} files',
                  style: const TextStyle(
                      fontSize: 11, color: Colors.black45),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          ...shown.map(
            (rf) => Padding(
              padding: const EdgeInsets.only(left: 38, right: 16, bottom: 1),
              child: Row(
                children: [
                  Icon(
                    _dotIcon(rf),
                    size: 7,
                    color: _dotColor(rf),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      rf.targetRelativePath,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.black54),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (overflow > 0)
            Padding(
              padding: const EdgeInsets.only(left: 50, bottom: 4),
              child: Text(
                '… and $overflow more',
                style: const TextStyle(
                    fontSize: 11, color: Colors.black38),
              ),
            ),
          Divider(height: 1, color: Colors.grey.shade100),
        ],
      ],
    );
  }
}

import 'package:flutter/material.dart';

import 'consolidate_models.dart';
import 'consolidate_service.dart';

// ---------------------------------------------------------------------------
// ConsolidateScan2Screen — Screen 3
//
// Phase 3.1 — Hashing progress:
//   Deterministic progress bar ("Analysed X of Y files") driven by totalFiles
//   from Scan 1.  ETA shown after 5 seconds of data.
//
// Phase 3.2 — Review / decisions (agreed 2026-04-10):
//   • Stats band (files to copy, duplicates removed, output size, issue count)
//   • Two-panel layout:
//       Left  — Navigable source trees (one collapsible root per source folder)
//       Right — Navigable merged target tree
//   • Indicator system:
//       File teal dot  = name collision
//       File green dot = clean copy or duplicate winner
//       File grey + strikethrough = duplicate loser (skip_duplicate)
//       Folder small dot = cascade aid (subtree contains file with issue)
//   • Issues panel — vertical scrollable full-width cards below trees:
//       Collision cards: description, "Show in tree" mini-list, editable names,
//                        Dismiss button; hotlink: dot tap → scrolls to card
//       Ambiguity cards: description, file list, Dismiss button
//   • Build button blocked until all issue cards are dismissed
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Indicator colours (agreed 2026-04-10)
// ---------------------------------------------------------------------------

const _kTeal = Color(0xFF0A7764);       // collision
const _kOrange = Color(0xFFBF5700);     // ambiguity (future)
const _kGreen = Color(0xFF1A7F37);      // clean copy
const _kBlueFolder = Color(0xFF0E70C0); // normal folder accent

// ---------------------------------------------------------------------------
// _TreeNode — navigable tree data structure
// ---------------------------------------------------------------------------

class _TreeNode {
  _TreeNode({required this.name, required this.path, this.routedFile});

  final String name; // segment name (e.g. "Photos")
  final String path; // full relative path (e.g. "Photos/2014")
  RoutedFile? routedFile; // non-null → file leaf

  final Map<String, _TreeNode> _children = {};

  bool get isFolder => routedFile == null;

  List<_TreeNode> get sortedChildren {
    final list = _children.values.toList();
    list.sort((a, b) {
      // Folders before files, then alphabetical
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  /// Build a tree from [files] using [pathOf] to extract the path string.
  static _TreeNode build(
    Iterable<RoutedFile> files,
    String Function(RoutedFile) pathOf,
  ) {
    final root = _TreeNode(name: '', path: '');
    for (final rf in files) {
      final rawPath = pathOf(rf);
      final parts =
          rawPath.split('/').where((p) => p.isNotEmpty).toList();
      if (parts.isEmpty) continue;
      _TreeNode current = root;
      for (var i = 0; i < parts.length; i++) {
        final segment = parts[i];
        final segPath = parts.sublist(0, i + 1).join('/');
        final isLeaf = i == parts.length - 1;
        if (!current._children.containsKey(segment)) {
          current._children[segment] = _TreeNode(
            name: segment,
            path: segPath,
            routedFile: isLeaf ? rf : null,
          );
        } else if (isLeaf) {
          current._children[segment]!.routedFile = rf;
        }
        current = current._children[segment]!;
      }
    }
    return root;
  }
}

/// Visual status for a file in the tree.
enum _FileStatus { cleanCopy, duplicate, collision }

// ---------------------------------------------------------------------------
// ConsolidateScan2Screen
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

  // ETA tracking — only shown after _etaMinSeconds of elapsed data.
  static const _etaMinSeconds = 5;
  DateTime? _scanStartTime;
  String? _etaLabel; // null until confident

  // ---------------------------------------------------------------------------
  // 3.2 — Review state
  // ---------------------------------------------------------------------------

  ContentScanComplete? _result;

  // Navigable tree structures.
  final Map<String, _TreeNode> _treesPerSource = {};
  _TreeNode? _targetTree;

  // Issue lookup sets (O(1) checks during tree render).
  final Set<String> _collisionSourceKeys = {}; // '${src}|${relPath}'
  final Set<String> _collisionTargetPaths = {}; // targetRelativePath
  final Set<String> _sourceFolderPathsWithIssue = {}; // relative folder paths
  final Set<String> _targetFolderPathsWithIssue = {}; // relative folder paths

  // Maps file key → issue card ID (for hotlink: dot tap → scroll to card).
  final Map<String, String> _sourceKeyToIssueId = {};
  final Map<String, String> _targetPathToIssueId = {};

  // For each collision, the routing entry that "won" (not renamed).
  final Map<String, RoutedFile?> _collisionWinners = {};

  // Name controllers keyed by '${sourceFolder}|${sourceRelativePath}'.
  final Map<String, TextEditingController> _nameControllers = {};

  // Set of dismissed issue IDs.
  // Collision: 'collision|${targetRelativePath}'
  // Ambiguity: 'ambiguity|$index'
  final Set<String> _dismissedIssues = {};

  // Hotlink state.
  final Map<String, GlobalKey> _cardKeys = {};
  final ScrollController _issuesPanelController = ScrollController();
  String? _highlightedIssueId;

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
    _issuesPanelController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Scan
  // ---------------------------------------------------------------------------

  void _runScan() {
    _scanStartTime = DateTime.now();
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
          final hashed = event.filesScanned;
          final elapsed =
              DateTime.now().difference(_scanStartTime!).inSeconds;
          String? eta;
          if (elapsed >= _etaMinSeconds &&
              hashed > 0 &&
              widget.totalFiles > hashed) {
            final rate = hashed / elapsed;
            final remaining = (widget.totalFiles - hashed) / rate;
            final mins = (remaining / 60).floor();
            final secs = (remaining % 60).round();
            if (mins > 0) {
              eta = 'About $mins minute${mins == 1 ? '' : 's'} remaining';
            } else {
              eta = 'About $secs second${secs == 1 ? '' : 's'} remaining';
            }
          }
          setState(() {
            _filesHashed = hashed;
            _etaLabel = eta;
          });
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
    // 1. Build navigable source trees.
    for (final folder in widget.sourceFolders) {
      final files =
          result.routing.where((rf) => rf.sourceFolder == folder);
      _treesPerSource[folder] =
          _TreeNode.build(files, (rf) => rf.sourceRelativePath);
    }

    // 2. Build navigable target tree.
    _targetTree =
        _TreeNode.build(result.routing, (rf) => rf.targetRelativePath);

    // 3. Build routing index for quick lookups.
    final routingIndex = <String, RoutedFile>{};
    for (final rf in result.routing) {
      routingIndex['${rf.sourceFolder}|${rf.sourceRelativePath}'] = rf;
    }

    // 4. Process collisions → populate lookup sets + name controllers.
    for (final collision in result.collisions) {
      final issueId = 'collision|${collision.targetRelativePath}';

      // Find winner (copy action, not a renamed entry).
      final entryKeys = collision.entries
          .map((e) => '${e.sourceFolder}|${e.sourceRelativePath}')
          .toSet();
      final winner = result.routing
          .where((rf) =>
              rf.targetRelativePath == collision.targetRelativePath &&
              rf.action == 'copy' &&
              !entryKeys.contains(
                  '${rf.sourceFolder}|${rf.sourceRelativePath}'))
          .firstOrNull;
      _collisionWinners[collision.targetRelativePath] = winner;

      // Mark the winner as a collision source.
      if (winner != null) {
        final key =
            '${winner.sourceFolder}|${winner.sourceRelativePath}';
        _collisionSourceKeys.add(key);
        _collisionTargetPaths.add(winner.targetRelativePath);
        _sourceKeyToIssueId[key] = issueId;
        _targetPathToIssueId[winner.targetRelativePath] = issueId;
        _nameControllers[key] ??= TextEditingController(
          text: winner.targetRelativePath,
        );
      }

      // Mark each renamed entry.
      _collisionTargetPaths.add(collision.targetRelativePath);
      _targetPathToIssueId[collision.targetRelativePath] = issueId;

      for (final entry in collision.entries) {
        final key =
            '${entry.sourceFolder}|${entry.sourceRelativePath}';
        _collisionSourceKeys.add(key);
        _collisionTargetPaths.add(entry.renamedTo);
        _sourceKeyToIssueId[key] = issueId;
        _targetPathToIssueId[entry.renamedTo] = issueId;
        final rf = routingIndex[key];
        _nameControllers[key] ??= TextEditingController(
          text: rf?.targetRelativePath ?? entry.renamedTo,
        );
      }
    }

    // 5. Compute folder cascade sets (O(n), used for O(1) folder indicator).
    for (final key in _collisionSourceKeys) {
      final parts = key.split('|');
      if (parts.length >= 2) {
        _addAncestors(_sourceFolderPathsWithIssue, parts[1]);
      }
    }
    for (final targetPath in _collisionTargetPaths) {
      _addAncestors(_targetFolderPathsWithIssue, targetPath);
    }

    // 6. Create GlobalKeys for issue cards.
    for (final collision in result.collisions) {
      final id = 'collision|${collision.targetRelativePath}';
      _cardKeys[id] = GlobalKey();
    }
    for (var i = 0; i < result.ambiguities.length; i++) {
      _cardKeys['ambiguity|$i'] = GlobalKey();
    }
  }

  /// Add all ancestor folder paths of [filePath] to [set].
  void _addAncestors(Set<String> set, String filePath) {
    final segments = filePath.split('/');
    for (var i = 1; i < segments.length; i++) {
      set.add(segments.sublist(0, i).join('/'));
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  String _folderName(String path) => path.split('/').last;

  int get _totalIssues =>
      (_result?.collisions.length ?? 0) +
      (_result?.ambiguities.length ?? 0);

  bool get _allIssuesDismissed => _dismissedIssues.length >= _totalIssues;

  _FileStatus _sourceFileStatus(RoutedFile rf) {
    final key = '${rf.sourceFolder}|${rf.sourceRelativePath}';
    if (_collisionSourceKeys.contains(key)) return _FileStatus.collision;
    if (rf.action == 'skip_duplicate') return _FileStatus.duplicate;
    return _FileStatus.cleanCopy;
  }

  _FileStatus _targetFileStatus(RoutedFile rf) {
    if (_collisionTargetPaths.contains(rf.targetRelativePath)) {
      return _FileStatus.collision;
    }
    if (rf.action == 'skip_duplicate') return _FileStatus.duplicate;
    return _FileStatus.cleanCopy;
  }

  /// Tap on a file indicator → scroll issues panel to the matching card.
  void _scrollToCard(String issueId) {
    setState(() => _highlightedIssueId = issueId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _cardKeys[issueId];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: 0.05,
        );
      }
    });
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
                _scanning
                    ? 'Step 3: Review — Identifying duplicates…'
                    : 'Step 3: Review',
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w600),
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
    final progress =
        total > 0 ? (_filesHashed / total).clamp(0.0, 1.0) : null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 80),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(value: progress, minHeight: 6),
            const SizedBox(height: 20),
            Text(
              total > 0
                  ? 'Analysed $_filesHashed of $total files'
                  : 'Identifying duplicates…',
              style: const TextStyle(fontSize: 15),
              textAlign: TextAlign.center,
            ),
            if (_etaLabel != null) ...[
              const SizedBox(height: 8),
              Text(
                _etaLabel!,
                style: const TextStyle(
                    fontSize: 13, color: Colors.black45),
                textAlign: TextAlign.center,
              ),
            ],
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
          _buildStat('To Copy', '${result.filesToCopy}',
              Colors.green.shade700),
          _buildStat('Duplicates', '${result.duplicatesSkipped}',
              Colors.orange.shade700),
          _buildStat('Output Size',
              _formatBytes(result.totalOutputSizeBytes),
              Colors.blue.shade700),
          _buildStat(
            'Issues',
            '$_totalIssues',
            _totalIssues == 0
                ? Colors.green.shade700
                : Colors.amber.shade800,
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
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color)),
        const SizedBox(height: 2),
        Text(label,
            style:
                const TextStyle(fontSize: 11, color: Colors.black54)),
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
              Expanded(child: _buildTargetPanel()),
            ],
          ),
        ),
        if (hasIssues) ...[
          Divider(height: 1, color: Colors.grey.shade200),
          SizedBox(
            height: 300,
            child: _buildIssuesPanel(result),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Left panel — Navigable source trees
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
              final tree = _treesPerSource[folder];
              if (tree == null) return const SizedBox.shrink();
              return _SourceRootSection(
                key: ValueKey(folder),
                rootName: _folderName(folder),
                tree: tree,
                accentColor: _folderColor(i),
                getStatus: _sourceFileStatus,
                hasFolderIssue: (node) =>
                    _sourceFolderPathsWithIssue.contains(node.path),
                getIssueKey: (rf) =>
                    _sourceKeyToIssueId[
                        '${rf.sourceFolder}|${rf.sourceRelativePath}'],
                onIssueTap: _scrollToCard,
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Right panel — Navigable target tree
  // ---------------------------------------------------------------------------

  Widget _buildTargetPanel() {
    final tree = _targetTree;
    if (tree == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPanelHeader('Proposed Output', Icons.folder_outlined),
        Expanded(
          child: ListView(
            children: tree.sortedChildren.map((child) {
              return _TreeNodeRow(
                key: ValueKey(child.path),
                node: child,
                depth: 0,
                accentColor: _kBlueFolder,
                getStatus: _targetFileStatus,
                hasFolderIssue: (node) =>
                    _targetFolderPathsWithIssue.contains(node.path),
                getIssueKey: (rf) =>
                    _targetPathToIssueId[rf.targetRelativePath],
                onIssueTap: _scrollToCard,
              );
            }).toList(),
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
        border:
            Border(bottom: BorderSide(color: Colors.grey.shade200)),
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
  // Issues panel — full-width vertical scrollable cards
  // ---------------------------------------------------------------------------

  Widget _buildIssuesPanel(ContentScanComplete result) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          decoration: BoxDecoration(
            color: Colors.orange.shade50,
            border: Border(
                bottom: BorderSide(color: Colors.orange.shade100)),
          ),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 15, color: Colors.orange.shade800),
              const SizedBox(width: 6),
              Text(
                '$_totalIssues issue${_totalIssues == 1 ? '' : 's'} — '
                'dismiss all to enable Build',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.orange.shade900),
              ),
              const Spacer(),
              Text(
                '${_dismissedIssues.length} / $_totalIssues dismissed',
                style: TextStyle(
                    fontSize: 11, color: Colors.orange.shade800),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            controller: _issuesPanelController,
            padding: const EdgeInsets.all(12),
            children: [
              ...result.collisions.asMap().entries.map((entry) {
                final id =
                    'collision|${entry.value.targetRelativePath}';
                return _buildCollisionCard(
                  collision: entry.value,
                  id: id,
                  dismissed: _dismissedIssues.contains(id),
                  highlighted: _highlightedIssueId == id,
                );
              }),
              ...result.ambiguities.asMap().entries.map((entry) {
                final id = 'ambiguity|${entry.key}';
                return _buildAmbiguityCard(
                  ambiguity: entry.value,
                  id: id,
                  dismissed: _dismissedIssues.contains(id),
                  highlighted: _highlightedIssueId == id,
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
    required bool highlighted,
  }) {
    final winner = _collisionWinners[collision.targetRelativePath];

    return Container(
      key: _cardKeys[id],
      margin: const EdgeInsets.only(bottom: 10),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: highlighted
                ? _kTeal
                : dismissed
                    ? Colors.grey.shade200
                    : const Color(0xFF0A7764).withOpacity(0.35),
            width: highlighted ? 2 : 1,
          ),
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
                  Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: _kTeal,
                    ),
                  ),
                  const SizedBox(width: 8),
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
                        ? () => setState(() {
                              _dismissedIssues.remove(id);
                              _highlightedIssueId = null;
                            })
                        : () =>
                            setState(() => _dismissedIssues.add(id)),
                    child: Text(dismissed ? 'Reopen' : 'Dismiss'),
                  ),
                ],
              ),
              if (!dismissed) ...[
                const SizedBox(height: 8),
                const Text(
                  'Two files have different content but share the same '
                  'output path. Edit either name to resolve.',
                  style:
                      TextStyle(fontSize: 11, color: Colors.black54),
                ),
                const SizedBox(height: 10),
                // "Show in tree" mini-list.
                Text(
                  'Show in tree:',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey.shade600),
                ),
                const SizedBox(height: 3),
                if (winner != null)
                  _buildMiniTreeLink(
                      '${_folderName(winner.sourceFolder)} / '
                      '${winner.sourceRelativePath}'),
                ...collision.entries.map(
                  (e) => _buildMiniTreeLink(
                      '${_folderName(e.sourceFolder)} / '
                      '${e.sourceRelativePath}'),
                ),
                const SizedBox(height: 10),
                // Editable name rows.
                if (winner != null)
                  _buildEditableFileRow(
                    sourceFolder: winner.sourceFolder,
                    sourceRelPath: winner.sourceRelativePath,
                    label: 'Kept as',
                  ),
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
      ),
    );
  }

  Widget _buildMiniTreeLink(String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 14, bottom: 2),
      child: Row(
        children: [
          Container(
            width: 5,
            height: 5,
            margin: const EdgeInsets.only(right: 6, top: 1),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: _kTeal,
            ),
          ),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: _kTeal),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
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
                  style: const TextStyle(
                      fontSize: 10, color: Colors.black45),
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
                style: const TextStyle(
                    fontSize: 11, color: Colors.black38)),
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
    required bool highlighted,
  }) {
    return Container(
      key: _cardKeys[id],
      margin: const EdgeInsets.only(bottom: 10),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: highlighted
                ? _kOrange
                : dismissed
                    ? Colors.grey.shade200
                    : Colors.orange.shade200,
            width: highlighted ? 2 : 1,
          ),
        ),
        color: dismissed ? Colors.grey.shade50 : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: _kOrange,
                    ),
                  ),
                  const SizedBox(width: 8),
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
                        ? () => setState(() {
                              _dismissedIssues.remove(id);
                              _highlightedIssueId = null;
                            })
                        : () =>
                            setState(() => _dismissedIssues.add(id)),
                    child: Text(dismissed ? 'Reopen' : 'Dismiss'),
                  ),
                ],
              ),
              if (!dismissed && ambiguity.files.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Show in tree:',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey.shade600),
                ),
                const SizedBox(height: 3),
                ...ambiguity.files.take(5).map(
                      (f) => _buildMiniTreeLink(f),
                    ),
                if (ambiguity.files.length > 5)
                  Padding(
                    padding: const EdgeInsets.only(left: 14),
                    child: Text(
                      '… and ${ambiguity.files.length - 5} more',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.black45),
                    ),
                  ),
              ],
            ],
          ),
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
      padding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        border:
            Border(top: BorderSide(color: Colors.grey.shade200)),
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
                  color: canBuild
                      ? Colors.black54
                      : Colors.amber.shade800),
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
// _SourceRootSection — collapsible root node for one source folder
// ---------------------------------------------------------------------------

class _SourceRootSection extends StatefulWidget {
  const _SourceRootSection({
    super.key,
    required this.rootName,
    required this.tree,
    required this.accentColor,
    required this.getStatus,
    required this.hasFolderIssue,
    required this.getIssueKey,
    required this.onIssueTap,
  });

  final String rootName;
  final _TreeNode tree;
  final Color accentColor;
  final _FileStatus Function(RoutedFile) getStatus;
  final bool Function(_TreeNode) hasFolderIssue;
  final String? Function(RoutedFile) getIssueKey;
  final void Function(String) onIssueTap;

  @override
  State<_SourceRootSection> createState() => _SourceRootSectionState();
}

class _SourceRootSectionState extends State<_SourceRootSection> {
  bool _expanded = true;

  int _countFiles(_TreeNode node) {
    if (!node.isFolder) return 1;
    return node.sortedChildren
        .fold(0, (sum, c) => sum + _countFiles(c));
  }

  @override
  Widget build(BuildContext context) {
    final fileCount = _countFiles(widget.tree);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Root header.
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.grey.shade50,
            child: Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.expand_more
                      : Icons.chevron_right,
                  size: 16,
                  color: widget.accentColor,
                ),
                const SizedBox(width: 3),
                Icon(Icons.folder_special,
                    size: 15, color: widget.accentColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.rootName,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: widget.accentColor),
                  ),
                ),
                Text(
                  '$fileCount files',
                  style: const TextStyle(
                      fontSize: 11, color: Colors.black45),
                ),
              ],
            ),
          ),
        ),
        // Children.
        if (_expanded)
          ...widget.tree.sortedChildren.map((child) => _TreeNodeRow(
                key: ValueKey(child.path),
                node: child,
                depth: 0,
                accentColor: widget.accentColor,
                getStatus: widget.getStatus,
                hasFolderIssue: widget.hasFolderIssue,
                getIssueKey: widget.getIssueKey,
                onIssueTap: widget.onIssueTap,
              )),
        Divider(height: 1, color: Colors.grey.shade100),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _TreeNodeRow — recursive folder/file row with colour indicators
// ---------------------------------------------------------------------------

class _TreeNodeRow extends StatefulWidget {
  const _TreeNodeRow({
    super.key,
    required this.node,
    required this.depth,
    required this.accentColor,
    required this.getStatus,
    required this.hasFolderIssue,
    required this.getIssueKey,
    required this.onIssueTap,
  });

  final _TreeNode node;
  final int depth;
  final Color accentColor;
  final _FileStatus Function(RoutedFile) getStatus;

  /// Returns true if [node] (a folder) has any issue files in its subtree.
  final bool Function(_TreeNode) hasFolderIssue;

  /// Returns the issue card ID for a file, or null if none.
  final String? Function(RoutedFile) getIssueKey;

  final void Function(String issueId) onIssueTap;

  @override
  State<_TreeNodeRow> createState() => _TreeNodeRowState();
}

class _TreeNodeRowState extends State<_TreeNodeRow> {
  bool _expanded = true;

  double get _indent => 12.0 + widget.depth * 14.0;

  @override
  Widget build(BuildContext context) {
    return widget.node.isFolder ? _buildFolder() : _buildFile();
  }

  Widget _buildFolder() {
    final node = widget.node;
    final hasIssue = widget.hasFolderIssue(node);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: EdgeInsets.only(
                left: _indent, right: 16, top: 5, bottom: 5),
            child: Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.expand_more
                      : Icons.chevron_right,
                  size: 15,
                  color: Colors.grey.shade500,
                ),
                const SizedBox(width: 2),
                Icon(Icons.folder,
                    size: 14, color: widget.accentColor),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    node.name,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey.shade800),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Cascade dot — signals issue in subtree.
                if (hasIssue)
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(left: 4),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: _kTeal,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_expanded)
          ...node.sortedChildren.map((child) => _TreeNodeRow(
                key: ValueKey(child.path),
                node: child,
                depth: widget.depth + 1,
                accentColor: widget.accentColor,
                getStatus: widget.getStatus,
                hasFolderIssue: widget.hasFolderIssue,
                getIssueKey: widget.getIssueKey,
                onIssueTap: widget.onIssueTap,
              )),
      ],
    );
  }

  Widget _buildFile() {
    final node = widget.node;
    final rf = node.routedFile!;
    final status = widget.getStatus(rf);
    final isDuplicate = status == _FileStatus.duplicate;
    final isCollision = status == _FileStatus.collision;
    final dotColor = isCollision ? _kTeal : _kGreen;
    final issueKey = isCollision ? widget.getIssueKey(rf) : null;

    return Padding(
      padding: EdgeInsets.only(
          left: _indent + 22, right: 16, top: 2, bottom: 2),
      child: Row(
        children: [
          Icon(
            Icons.description_outlined,
            size: 12,
            color: isDuplicate
                ? Colors.grey.shade300
                : Colors.grey.shade500,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              node.name,
              style: TextStyle(
                fontSize: 11,
                color: isDuplicate
                    ? Colors.grey.shade400
                    : Colors.grey.shade700,
                decoration:
                    isDuplicate ? TextDecoration.lineThrough : null,
                decorationColor: Colors.grey.shade400,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Status dot (right of name).
          if (!isDuplicate) ...[
            const SizedBox(width: 4),
            GestureDetector(
              onTap: issueKey != null
                  ? () => widget.onIssueTap(issueKey)
                  : null,
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

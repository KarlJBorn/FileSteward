import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'rationalize_events.dart';
import 'rationalize_models.dart';
import 'rationalize_service.dart';

// ---------------------------------------------------------------------------
// Theme constants
// ---------------------------------------------------------------------------

const _kBg = Color(0xFF1E1E1E);
const _kPanelBg = Color(0xFF252526);
const _kDivider = Color(0xFF3E3E42);
const _kText = Color(0xFFCCCCCC);
const _kSubtext = Color(0xFF858585);
const _kBlue = Color(0xFF0E70C0);
const _kIssueBadge = Color(0xFFCD3131);
const _kWarningBadge = Color(0xFFCCA700);
const _kSuccessBadge = Color(0xFF16825D);

// Finding action colors — named constants so the palette is a one-line change.
const _kRemoveColor = Color(0xFFCD3131); // red — proposed removal
const _kRenameColor = Color(0xFFCCA700); // orange — proposed rename
const _kMoveColor = Color(0xFF4FC1FF); // blue — proposed move
const _kRenameTargetColor = Color(0xFF89D185); // green italic — rename in target panel
const _kCollisionSuffixColor = Color(0xFFD7BA7D); // amber italic — auto-suffixed rename collision
const _kUserRemoveColor = Color(0xFFCD3131); // same red — user-initiated removal

// ---------------------------------------------------------------------------
// Phase enum
// ---------------------------------------------------------------------------

enum _Phase { folderPicker, scanning, findings, building, swapConfirm, results }

// ---------------------------------------------------------------------------
// _TreeNode — one row in either panel
// ---------------------------------------------------------------------------

class _TreeNode {
  final String relativePath;
  final String absolutePath;
  final String name;
  final int depth;
  final bool isFile;

  /// Engine finding on this exact path, if any.
  final RationalizeFinding? finding;

  /// In the target panel: this node shows a rename's new name.
  final bool isRenamedTarget;

  /// In the target panel: this node shows a move destination.
  final bool isMovedTarget;

  /// User marked this subtree for removal via right-click.
  final bool isUserRemoval;

  const _TreeNode({
    required this.relativePath,
    required this.absolutePath,
    required this.name,
    required this.depth,
    this.isFile = false,
    this.finding,
    this.isRenamedTarget = false,
    this.isMovedTarget = false,
    this.isUserRemoval = false,
  });
}

// ---------------------------------------------------------------------------
// RationalizeScreen
// ---------------------------------------------------------------------------

class RationalizeScreen extends StatefulWidget {
  const RationalizeScreen({super.key, this.initialFolder});

  /// When provided, skips the folder picker and begins scanning immediately.
  final String? initialFolder;

  @override
  State<RationalizeScreen> createState() => _RationalizeScreenState();
}

class _RationalizeScreenState extends State<RationalizeScreen> {
  final _service = const RationalizeService();

  _Phase _phase = _Phase.folderPicker;
  String? _selectedFolder;
  RationalizeSession? _session;

  // Scan progress
  int _foldersScanned = 0;
  String _currentPath = '';

  // Findings payload
  FindingsPayload? _payload;

  // Panel B decision model:
  // All engine findings are applied by default. Explicit reject removes the
  // effect from the right panel. Explicit accept re-applies after a reject.
  // Absent key = default (applied).
  // true = explicitly accepted (re-applied after reject)
  // false = explicitly rejected (removed from right panel)
  final Map<String, bool> _decisions = {};

  // User-overridden destination paths for rename/move: finding id → abs path.
  final Map<String, String> _destinationOverrides = {};

  // User-initiated subtree removals: relative path → absolute path.
  final Map<String, String> _userRemovedPaths = {};

  // Currently open detail drawer finding id.
  String? _drawerFindingId;

  // Build phase state
  BuildResult? _buildResult;
  int _buildFoldersDone = 0;
  int _buildFoldersTotal = 0;
  String _buildCurrentPath = '';

  // Swap phase state
  SwapResult? _swapResult;

  // Legacy execution result (kept during transition)
  ExecutionResult? _executionResult;

  // ---------------------------------------------------------------------------
  // Computed helpers
  // ---------------------------------------------------------------------------

  Set<String> get _rejectedIds =>
      _decisions.entries.where((e) => !e.value).map((e) => e.key).toSet();

  /// Count of engine findings that will be applied (not rejected) + user removals.
  int get _pendingCount {
    final p = _payload;
    if (p == null) return _userRemovedPaths.length;
    final engine = p.findings.where((f) => _decisions[f.id] != false).length;
    return engine + _userRemovedPaths.length;
  }

  /// Count of explicitly rejected findings.
  int get _rejectedCount => _rejectedIds.length;

  String _effectiveDestination(RationalizeFinding f) =>
      _destinationOverrides[f.id] ?? f.absoluteDestination ?? '';

  // ---------------------------------------------------------------------------
  // Tree building
  // ---------------------------------------------------------------------------

  List<_TreeNode> _buildOriginalTree(FindingsPayload payload) {
    final base = payload.selectedFolder;
    final pathToFinding = <String, RationalizeFinding>{};
    for (final f in payload.findings) {
      pathToFinding[f.path] = f;
    }

    // Build from the full directory listing — every folder and file.
    final nodes = payload.entries.map((entry) {
      final path = entry.relativePath;
      final parts = path.split('/');
      return _TreeNode(
        relativePath: path,
        absolutePath: '$base/$path',
        name: parts.last,
        depth: parts.length - 1,
        isFile: entry.isFile,
        finding: entry.isFile ? null : pathToFinding[path],
        isUserRemoval: !entry.isFile && _userRemovedPaths.containsKey(path),
      );
    }).toList();

    // Also include any user-removed paths not already in the entry list
    // (shouldn't happen, but defensive).
    final existingPaths = nodes.map((n) => n.relativePath).toSet();
    for (final rel in _userRemovedPaths.keys) {
      if (!existingPaths.contains(rel)) {
        final parts = rel.split('/');
        nodes.add(_TreeNode(
          relativePath: rel,
          absolutePath: '$base/$rel',
          name: parts.last,
          depth: parts.length - 1,
          isUserRemoval: true,
        ));
      }
    }

    nodes.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return nodes;
  }

  /// Panel B: all engine findings applied by default; rejected findings reverted;
  /// user-initiated removals applied.
  List<_TreeNode> _buildTargetTree(FindingsPayload payload) {
    final base = payload.selectedFolder;
    final rejected = _rejectedIds;
    final original = _buildOriginalTree(payload);

    // Collect paths that will be absent from the target.
    final removedPaths = <String>{};
    for (final f in payload.findings) {
      if (f.action == FindingAction.remove && !rejected.contains(f.id)) {
        removedPaths.add(f.path);
      }
    }
    for (final rel in _userRemovedPaths.keys) {
      removedPaths.add(rel);
    }

    final result = <_TreeNode>[];

    for (final node in original) {
      // Omit nodes that are removed or under a removed subtree.
      final isRemoved = removedPaths.any((rp) =>
          node.relativePath == rp || node.relativePath.startsWith('$rp/'));
      if (isRemoved) continue;

      final f = node.finding;
      if (f != null && !rejected.contains(f.id)) {
        if (f.action == FindingAction.rename) {
          final dest = _effectiveDestination(f);
          final newName = dest.isNotEmpty ? dest.split('/').last : node.name;
          result.add(_TreeNode(
            relativePath: node.relativePath,
            absolutePath: node.absolutePath,
            name: newName,
            depth: node.depth,
            finding: f,
            isRenamedTarget: true,
          ));
          continue;
        } else if (f.action == FindingAction.move) {
          continue; // omit from original location; added at destination below
        }
      }
      result.add(node);
    }

    // Add move destinations for non-rejected move findings.
    for (final f in payload.findings) {
      if (f.action != FindingAction.move || rejected.contains(f.id)) continue;
      final dest = _effectiveDestination(f);
      if (dest.isEmpty) continue;

      final rel = dest.startsWith(base)
          ? dest.substring(base.length).replaceAll(RegExp(r'^/'), '')
          : dest.split('/').last;
      if (rel.isEmpty) continue;

      result.add(_TreeNode(
        relativePath: rel,
        absolutePath: dest,
        name: rel.split('/').last,
        depth: rel.split('/').length - 1,
        finding: f,
        isMovedTarget: true,
      ));
    }

    result.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return result;
  }

  void _addAncestors(String path, Set<String> out) {
    var p = path;
    while (p.isNotEmpty) {
      out.add(p);
      final slash = p.lastIndexOf('/');
      if (slash < 0) break;
      p = p.substring(0, slash);
    }
  }

  // ---------------------------------------------------------------------------
  // Decision actions
  // ---------------------------------------------------------------------------

  void _reject(String id) => setState(() {
        _decisions[id] = false;
        if (_drawerFindingId == id) _drawerFindingId = null;
      });

  void _accept(String id) => setState(() {
        _decisions[id] = true;
        if (_drawerFindingId == id) _drawerFindingId = null;
      });


  void _markForRemoval(String relativePath, String absolutePath) =>
      setState(() => _userRemovedPaths[relativePath] = absolutePath);

  void _unmarkForRemoval(String relativePath) =>
      setState(() => _userRemovedPaths.remove(relativePath));

  void _openDrawer(String id) => setState(() => _drawerFindingId = id);
  void _closeDrawer() => setState(() => _drawerFindingId = null);

  // ---------------------------------------------------------------------------
  // Scan
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    final folder = widget.initialFolder;
    if (folder != null && folder.isNotEmpty) {
      // Defer until after first frame so the widget tree is mounted.
      WidgetsBinding.instance.addPostFrameCallback((_) => _startScan(folder));
    }
  }

  /// Begin a scan for [path], resetting all state first.
  Future<void> _startScan(String path) async {
    setState(() {
      _selectedFolder = path;
      _phase = _Phase.scanning;
      _foldersScanned = 0;
      _currentPath = '';
      _payload = null;
      _decisions.clear();
      _destinationOverrides.clear();
      _userRemovedPaths.clear();
      _drawerFindingId = null;
      _executionResult = null;
      _buildResult = null;
      _swapResult = null;
      _buildFoldersDone = 0;
      _buildFoldersTotal = 0;
      _buildCurrentPath = '';
    });

    final session = await _service.startSession(path);
    if (!mounted) {
      await session.dispose();
      return;
    }
    _session = session;

    await for (final event in session.events) {
      if (!mounted) break;
      switch (event) {
        case RationalizeProgress(:final foldersScanned, :final currentPath):
          setState(() {
            _foldersScanned = foldersScanned;
            _currentPath = currentPath;
          });
        case RationalizeScanComplete(:final payload):
          setState(() {
            _payload = payload;
            _phase = _Phase.findings;
          });
        case RationalizeError(:final message):
          _showError(message);
          setState(() => _phase = _Phase.folderPicker);
          await session.dispose();
          _session = null;
      }
    }
  }

  Future<void> _pickFolderAndScan() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty || !mounted) return;
    await _startScan(path);
  }


  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  Future<void> _applyChanges() async {
    final session = _session;
    final payload = _payload;
    final folder = _selectedFolder;
    if (session == null || payload == null || folder == null) return;

    final now = DateTime.now().toUtc();
    final sessionId = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}T'
        '${now.hour.toString().padLeft(2, '0')}-'
        '${now.minute.toString().padLeft(2, '0')}-'
        '${now.second.toString().padLeft(2, '0')}';

    // All engine findings not explicitly rejected.
    final engineActions = payload.findings
        .where((f) => _decisions[f.id] != false)
        .map((f) => ExecutionActionItem(
              findingId: f.id,
              action: f.action,
              absolutePath: f.absolutePath,
              absoluteDestination: f.action != FindingAction.remove
                  ? _effectiveDestination(f)
                  : null,
            ))
        .toList();

    // User-initiated removals synthesized as remove actions.
    final userActions = _userRemovedPaths.entries.map((e) {
      return ExecutionActionItem(
        findingId: 'user_${e.key}',
        action: FindingAction.remove,
        absolutePath: e.value,
      );
    }).toList();

    // Target directory: source name + _rationalized, in the same parent.
    final sourceName = folder.split('/').last;
    final sourceParent = folder.substring(0, folder.length - sourceName.length)
        .replaceAll(RegExp(r'/$'), '');
    final targetPath = '$sourceParent/${sourceName}_rationalized';

    final cmd = BuildCommand(
      sourcePath: folder,
      targetPath: targetPath,
      sessionId: sessionId,
      actions: [...engineActions, ...userActions],
    );

    setState(() {
      _phase = _Phase.building;
      _buildFoldersDone = 0;
      _buildFoldersTotal = 0;
      _buildCurrentPath = '';
      _buildResult = null;
    });

    final result = await session.build(
      cmd,
      onProgress: (done, total, current) {
        if (!mounted) return;
        setState(() {
          _buildFoldersDone = done;
          _buildFoldersTotal = total;
          _buildCurrentPath = current;
        });
      },
    );

    if (!mounted) return;
    setState(() {
      _buildResult = result;
      _phase = result?.succeeded == true
          ? _Phase.swapConfirm
          : _Phase.results;
    });
  }

  // ---------------------------------------------------------------------------
  // Swap
  // ---------------------------------------------------------------------------

  Future<void> _confirmSwap() async {
    final session = _session;
    final buildResult = _buildResult;
    final folder = _selectedFolder;
    if (session == null || buildResult == null || folder == null) return;

    final cmd = SwapCommand(
      sourcePath: folder,
      targetPath: buildResult.targetPath,
    );

    final result = await session.swap(cmd);
    if (!mounted) return;
    setState(() {
      _swapResult = result;
      _phase = _Phase.results;
    });
  }

  // ---------------------------------------------------------------------------
  // Re-scan
  // ---------------------------------------------------------------------------

  Future<void> _rescan() async {
    await _session?.dispose();
    _session = null;
    await _pickFolderAndScan();
  }

  // ---------------------------------------------------------------------------
  // Context menu
  // ---------------------------------------------------------------------------

  void _showContextMenu(BuildContext ctx, Offset pos, _TreeNode node) {
    final finding = node.finding;
    final isUserMarked = _userRemovedPaths.containsKey(node.relativePath);
    final decision = finding != null ? _decisions[finding.id] : null;

    showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      color: const Color(0xFF2D2D30),
      items: <PopupMenuEntry<String>>[
        if (finding != null) ...[
          PopupMenuItem(
            value: 'accept',
            child: Text(
              decision == true ? 'Accepted ✓' : 'Accept — ${_actionLabel(finding)}',
              style: TextStyle(
                fontSize: 13,
                color: decision == true ? _kSuccessBadge : _kText,
              ),
            ),
          ),
          PopupMenuItem(
            value: 'reject',
            child: Text(
              decision == false ? 'Rejected ✗' : 'Reject this finding',
              style: TextStyle(
                fontSize: 13,
                color: decision == false ? _kSubtext : _kText,
              ),
            ),
          ),
          const PopupMenuDivider(),
        ],
        PopupMenuItem(
          value: isUserMarked ? 'unmark' : 'mark_remove',
          child: Text(
            isUserMarked ? 'Unmark for removal' : 'Mark subtree for removal',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      if (value == 'accept' && finding != null) _accept(finding.id);
      if (value == 'reject' && finding != null) _reject(finding.id);
      if (value == 'mark_remove') {
        _markForRemoval(node.relativePath, node.absolutePath);
      }
      if (value == 'unmark') _unmarkForRemoval(node.relativePath);
    });
  }

  String _actionLabel(RationalizeFinding f) => switch (f.action) {
        FindingAction.remove => 'Remove',
        FindingAction.rename => () {
            final dest = _effectiveDestination(f);
            final name = dest.isNotEmpty ? dest.split('/').last : '…';
            return 'Rename to "$name"';
          }(),
        FindingAction.move => 'Move to ${f.destination ?? '…'}',
      };

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message, style: const TextStyle(color: Colors.white)),
      backgroundColor: _kIssueBadge,
      duration: const Duration(seconds: 6),
    ));
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _kBg,
        dividerColor: _kDivider,
      ),
      child: Scaffold(
        backgroundColor: _kBg,
        appBar: _buildAppBar(),
        body: _buildBody(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _kPanelBg,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: _kText),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: Text(
        _selectedFolder != null
            ? _selectedFolder!.split('/').last
            : 'Rationalize',
        style: const TextStyle(color: _kText, fontSize: 14),
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: _kDivider),
      ),
    );
  }

  Widget _buildBody() => switch (_phase) {
        _Phase.folderPicker => _buildFolderPicker(),
        _Phase.scanning => _buildScanning(),
        _Phase.findings => _buildFindingsView(),
        _Phase.building => _buildBuilding(),
        _Phase.swapConfirm => _buildSwapConfirm(),
        _Phase.results => _buildResults(),
      };

  // ---------------------------------------------------------------------------
  // Phase: Folder picker
  // ---------------------------------------------------------------------------

  Widget _buildFolderPicker() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.folder_open, size: 64, color: _kSubtext),
          const SizedBox(height: 16),
          const Text('Choose a folder to rationalize',
              style: TextStyle(color: _kText, fontSize: 16)),
          const SizedBox(height: 8),
          const Text(
            'FileSteward will analyze the folder structure and\n'
            'propose improvements. Nothing is changed until you confirm.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _kSubtext, fontSize: 13),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kBlue,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Choose Folder…'),
            onPressed: _pickFolderAndScan,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Phase: Scanning
  // ---------------------------------------------------------------------------

  Widget _buildScanning() {
    return Center(
      child: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: _kBlue),
            const SizedBox(height: 24),
            const Text('Scanning folder structure…',
                style: TextStyle(color: _kText, fontSize: 14)),
            const SizedBox(height: 8),
            Text('$_foldersScanned folders scanned',
                style: const TextStyle(color: _kSubtext, fontSize: 12)),
            if (_currentPath.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(_currentPath,
                  style: const TextStyle(color: _kSubtext, fontSize: 11),
                  overflow: TextOverflow.ellipsis),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Phase: Findings — before/after tree panels
  // ---------------------------------------------------------------------------

  Widget _buildFindingsView() {
    final payload = _payload!;
    final originalNodes = _buildOriginalTree(payload);
    final targetNodes = _buildTargetTree(payload);
    final drawerFinding =
        _drawerFindingId != null ? payload.findById(_drawerFindingId!) : null;

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Left — original state
                  Expanded(
                    child: _OriginalTreePanel(
                      nodes: originalNodes,
                      decisions: _decisions,
                      userRemovedPaths: _userRemovedPaths,
                      drawerFindingId: _drawerFindingId,
                      onNodeTap: (node) {
                        if (node.finding != null) _openDrawer(node.finding!.id);
                      },
                      onNodeRightClick: _showContextMenu,
                    ),
                  ),
                  Container(width: 1, color: _kDivider),
                  // Right — target state
                  Expanded(
                    child: _TargetTreePanel(
                      nodes: targetNodes,
                      drawerFindingId: _drawerFindingId,
                      onNodeTap: (node) {
                        if (node.finding != null) _openDrawer(node.finding!.id);
                      },
                    ),
                  ),
                ],
              ),
              // Detail drawer
              if (drawerFinding != null)
                _DetailDrawerOverlay(
                  finding: drawerFinding,
                  decision: _decisions[drawerFinding.id],
                  destinationOverride: _destinationOverrides[drawerFinding.id],
                  onAccept: () => _accept(drawerFinding.id),
                  onReject: () => _reject(drawerFinding.id),
                  onClose: _closeDrawer,
                  onDestinationChanged: (path) => setState(
                    () => _destinationOverrides[drawerFinding.id] = path,
                  ),
                ),
            ],
          ),
        ),
        Container(height: 1, color: _kDivider),
        _BottomBar(
          pendingCount: _pendingCount,
          rejectedCount: _rejectedCount,
          onApply: _pendingCount > 0 ? _applyChanges : null,
          onDone: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Phase: Executing
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Phase: Building
  // ---------------------------------------------------------------------------

  Widget _buildBuilding() {
    final total = _buildFoldersTotal;
    final done = _buildFoldersDone;
    final progress = total > 0 ? done / total : null;
    final current = _buildCurrentPath.split('/').last;

    return Center(
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              value: progress,
              color: _kBlue,
            ),
            const SizedBox(height: 24),
            const Text('Building rationalized copy…',
                style: TextStyle(color: _kText, fontSize: 14)),
            const SizedBox(height: 8),
            if (total > 0)
              Text('$done / $total folders',
                  style: const TextStyle(color: _kSubtext, fontSize: 12)),
            if (current.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                current,
                style: const TextStyle(color: _kSubtext, fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'Your original folder is not being modified.',
              style: TextStyle(color: _kSubtext, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Phase: Swap Confirmation
  // ---------------------------------------------------------------------------

  Widget _buildSwapConfirm() {
    final buildResult = _buildResult;
    final folder = _selectedFolder;
    if (buildResult == null || folder == null) {
      return const Center(
          child: Text('No build result.', style: TextStyle(color: _kText)));
    }

    final sourceName = folder.split('/').last;
    final oldName = '$sourceName.OLD';
    final targetName = buildResult.targetPath.split('/').last;

    return Center(
      child: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Rationalized copy is ready',
              style: TextStyle(
                  color: _kText, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '${buildResult.foldersCopied} folders · '
              '${buildResult.filesCopied} files copied · '
              '${buildResult.foldersOmitted} folders omitted',
              style: const TextStyle(color: _kSubtext, fontSize: 13),
            ),
            const SizedBox(height: 24),
            const Text(
              'Confirm swap to make it live:',
              style: TextStyle(color: _kText, fontSize: 13),
            ),
            const SizedBox(height: 12),
            _SwapRow(
              label: 'Original renamed to',
              value: oldName,
              color: _kSubtext,
            ),
            const SizedBox(height: 6),
            _SwapRow(
              label: 'Copy renamed to',
              value: sourceName,
              color: _kRenameTargetColor,
            ),
            const SizedBox(height: 24),
            Text(
              'You can delete $oldName at any time once you\'re satisfied.',
              style: const TextStyle(color: _kSubtext, fontSize: 12),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kText,
                    side: const BorderSide(color: _kDivider),
                  ),
                  onPressed: () async {
                    // Delete the rationalized copy — it's clutter if not committed.
                    final targetPath = _buildResult?.targetPath;
                    if (targetPath != null) {
                      final dir = Directory(targetPath);
                      if (dir.existsSync()) {
                        await dir.delete(recursive: true);
                      }
                    }
                    if (!mounted) return;
                    setState(() => _phase = _Phase.results);
                  },
                  child: const Text('Not yet'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _kBlue,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _confirmSwap,
                  child: const Text('Swap now'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Phase: Results
  // ---------------------------------------------------------------------------

  Widget _buildResults() {
    // Show swap result if available; fall back to build result.
    final swapResult = _swapResult;
    final buildResult = _buildResult;

    if (swapResult != null) {
      // Swap completed (success or failure).
      final ok = swapResult.succeeded;
      return Center(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                ok ? Icons.check_circle_outline : Icons.warning_amber_outlined,
                size: 48,
                color: ok ? _kSuccessBadge : _kWarningBadge,
              ),
              const SizedBox(height: 16),
              Text(
                ok ? 'Swap complete' : 'Swap failed',
                style: const TextStyle(
                    color: _kText, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              if (ok) ...[
                Text(
                  'Original backed up at:\n${swapResult.oldPath}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _kSubtext, fontSize: 12),
                ),
              ] else ...[
                Text(
                  swapResult.error ?? 'Unknown error.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _kIssueBadge, fontSize: 12),
                ),
              ],
              const SizedBox(height: 24),
              _ResultButtons(onDone: () => Navigator.of(context).pop(), onRescan: _rescan),
            ],
          ),
        ),
      );
    }

    if (buildResult != null) {
      // Build completed but swap was cancelled or failed before running.
      final ok = buildResult.succeeded;
      return Center(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                ok ? Icons.check_circle_outline : Icons.warning_amber_outlined,
                size: 48,
                color: ok ? _kSuccessBadge : _kWarningBadge,
              ),
              const SizedBox(height: 16),
              Text(
                ok ? 'Build complete — swap not applied' : 'Build failed',
                style: const TextStyle(
                    color: _kText, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              if (ok) ...[
                Text(
                  'Rationalized copy is at:\n${buildResult.targetPath}\n\n'
                  'Your original is untouched.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _kSubtext, fontSize: 12),
                ),
              ] else ...[
                Text(
                  buildResult.error ?? 'Unknown error.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _kIssueBadge, fontSize: 12),
                ),
              ],
              const SizedBox(height: 24),
              _ResultButtons(onDone: () => Navigator.of(context).pop(), onRescan: _rescan),
            ],
          ),
        ),
      );
    }

    return const Center(
        child: Text('No result.', style: TextStyle(color: _kText)));
  }
}

// ---------------------------------------------------------------------------
// _SwapRow — one row in the swap confirmation screen
// ---------------------------------------------------------------------------

class _SwapRow extends StatelessWidget {
  const _SwapRow({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('$label: ', style: const TextStyle(color: _kSubtext, fontSize: 13)),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _ResultButtons — Done + Re-scan row reused in results screens
// ---------------------------------------------------------------------------

class _ResultButtons extends StatelessWidget {
  const _ResultButtons({required this.onDone, required this.onRescan});
  final VoidCallback onDone;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: _kText,
            side: const BorderSide(color: _kDivider),
          ),
          onPressed: onDone,
          child: const Text('Done'),
        ),
        const SizedBox(width: 12),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _kBlue,
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Re-scan'),
          onPressed: onRescan,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _OriginalTreePanel — left panel, color-coded by action
// ---------------------------------------------------------------------------

class _OriginalTreePanel extends StatelessWidget {
  const _OriginalTreePanel({
    required this.nodes,
    required this.decisions,
    required this.userRemovedPaths,
    required this.drawerFindingId,
    required this.onNodeTap,
    required this.onNodeRightClick,
  });

  final List<_TreeNode> nodes;
  final Map<String, bool> decisions;
  final Map<String, String> userRemovedPaths;
  final String? drawerFindingId;
  final void Function(_TreeNode) onNodeTap;
  final void Function(BuildContext, Offset, _TreeNode) onNodeRightClick;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _PanelHeader(
          title: 'Original',
          subtitle: '${nodes.where((n) => !n.isFile).length} folders · ${nodes.where((n) => n.isFile).length} files',
        ),
        Expanded(
          child: ListView.builder(
            itemCount: nodes.length,
            itemBuilder: (ctx, i) {
              final node = nodes[i];
              final f = node.finding;

              Color? nameColor;
              // Check if this node or any ancestor is user-marked for removal.
              final isUnderUserRemoval = userRemovedPaths.keys.any((rp) =>
                  node.relativePath == rp ||
                  node.relativePath.startsWith('$rp/'));
              if (node.isUserRemoval || isUnderUserRemoval) {
                nameColor = _kUserRemoveColor;
              } else if (f != null) {
                nameColor = switch (f.action) {
                  FindingAction.remove => _kRemoveColor,
                  FindingAction.rename => _kRenameColor,
                  FindingAction.move => _kMoveColor,
                };
              }

              // Dim color when explicitly rejected.
              final isRejected = f != null && decisions[f.id] == false;

              return _TreeNodeRow(
                name: node.name,
                depth: node.depth,
                isFile: node.isFile,
                nameColor: isRejected ? _kSubtext : nameColor,
                isItalic: false,
                isStrikethrough: isRejected,
                decision: f != null ? decisions[f.id] : null,
                isFocused: f != null && f.id == drawerFindingId,
                onTap: () => onNodeTap(node),
                onSecondaryTap: (pos) => onNodeRightClick(ctx, pos, node),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _TargetTreePanel — right panel, clean target state
// ---------------------------------------------------------------------------

class _TargetTreePanel extends StatelessWidget {
  const _TargetTreePanel({
    required this.nodes,
    required this.drawerFindingId,
    required this.onNodeTap,
  });

  final List<_TreeNode> nodes;
  final String? drawerFindingId;
  final void Function(_TreeNode) onNodeTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _PanelHeader(
          title: 'Target',
          subtitle: '${nodes.where((n) => !n.isFile).length} folders · ${nodes.where((n) => n.isFile).length} files',
        ),
        Expanded(
          child: nodes.isEmpty
              ? const Center(
                  child: Text(
                    'Nothing to show — all findings rejected.',
                    style: TextStyle(color: _kSubtext, fontSize: 13),
                  ),
                )
              : ListView.builder(
                  itemCount: nodes.length,
                  itemBuilder: (_, i) {
                    final node = nodes[i];
                    final f = node.finding;

                    Color? nameColor;
                    bool isItalic = false;
                    if (node.isRenamedTarget || node.isMovedTarget) {
                      nameColor = _kRenameTargetColor;
                      isItalic = true;
                    }

                    return _TreeNodeRow(
                      name: node.name,
                      depth: node.depth,
                      isFile: node.isFile,
                      nameColor: nameColor,
                      isItalic: isItalic,
                      isStrikethrough: false,
                      decision: null,
                      isFocused: f != null && f.id == drawerFindingId,
                      onTap: () => onNodeTap(node),
                      onSecondaryTap: null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _PanelHeader
// ---------------------------------------------------------------------------

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 36,
          color: _kPanelBg,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text(title,
                  style: const TextStyle(
                      color: _kText,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Text(subtitle,
                  style: const TextStyle(color: _kSubtext, fontSize: 11)),
            ],
          ),
        ),
        Container(height: 1, color: _kDivider),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _TreeNodeRow
// ---------------------------------------------------------------------------

class _TreeNodeRow extends StatelessWidget {
  const _TreeNodeRow({
    required this.name,
    required this.depth,
    required this.nameColor,
    required this.isItalic,
    required this.isStrikethrough,
    required this.decision,
    required this.isFocused,
    required this.onTap,
    required this.onSecondaryTap,
    this.isFile = false,
  });

  final String name;
  final int depth;
  final Color? nameColor;
  final bool isItalic;
  final bool isStrikethrough;
  final bool? decision; // true=accepted, false=rejected, null=default
  final bool isFocused;
  final bool isFile;
  final VoidCallback? onTap;
  final void Function(Offset)? onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    final textColor = nameColor ?? (isFile ? _kSubtext : _kText);
    final iconColor = nameColor ?? (isFile ? _kSubtext : const Color(0xFF4FC1FF));

    return GestureDetector(
      onTap: onTap,
      onSecondaryTapUp: onSecondaryTap != null
          ? (d) => onSecondaryTap!(d.globalPosition)
          : null,
      child: Container(
        height: 22,
        color: isFocused
            ? _kBlue.withValues(alpha: 0.2)
            : Colors.transparent,
        padding: EdgeInsets.only(left: 12.0 + depth * 16.0, right: 8),
        child: Row(
          children: [
            Icon(
              isFile ? Icons.insert_drive_file_outlined : Icons.folder,
              size: 13,
              color: iconColor,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
                  decoration: isStrikethrough
                      ? TextDecoration.lineThrough
                      : TextDecoration.none,
                  decorationColor: _kSubtext,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Decision indicator
            if (decision == true)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.check_circle, size: 12, color: _kSuccessBadge),
              )
            else if (decision == false)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.cancel, size: 12, color: _kSubtext),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _DetailDrawerOverlay
// ---------------------------------------------------------------------------

class _DetailDrawerOverlay extends StatefulWidget {
  const _DetailDrawerOverlay({
    required this.finding,
    required this.decision,
    required this.destinationOverride,
    required this.onAccept,
    required this.onReject,
    required this.onClose,
    required this.onDestinationChanged,
  });

  final RationalizeFinding finding;
  final bool? decision;
  final String? destinationOverride;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onClose;
  final void Function(String) onDestinationChanged;

  @override
  State<_DetailDrawerOverlay> createState() => _DetailDrawerOverlayState();
}

class _DetailDrawerOverlayState extends State<_DetailDrawerOverlay> {
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
        text: _suggestedName(widget.finding, widget.destinationOverride));
  }

  @override
  void didUpdateWidget(_DetailDrawerOverlay old) {
    super.didUpdateWidget(old);
    if (old.finding.id != widget.finding.id) {
      _nameController.text =
          _suggestedName(widget.finding, widget.destinationOverride);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  static String _suggestedName(RationalizeFinding f, String? override) {
    if (override != null && override.isNotEmpty) {
      return override.split('/').last;
    }
    final dest = f.destination ?? f.absoluteDestination ?? '';
    return dest.isNotEmpty ? dest.split('/').last : '';
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.finding;
    final isRename = f.action == FindingAction.rename;
    final accepted = widget.decision == true;
    final rejected = widget.decision == false;
    // null = default applied state (Panel B)
    final isDefault = widget.decision == null;

    return Positioned(
      top: 0,
      right: 0,
      bottom: 0,
      width: 340,
      child: Container(
        decoration: BoxDecoration(
          color: _kPanelBg,
          border: Border(left: BorderSide(color: _kDivider)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 16,
              offset: const Offset(-4, 0),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: _kDivider))),
              child: Row(
                children: [
                  _FindingTypeBadge(type: f.findingType),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      f.displayName,
                      style: const TextStyle(
                          color: _kText,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16, color: _kSubtext),
                    onPressed: widget.onClose,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),

            // Body
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Type + severity
                    Row(
                      children: [
                        Text(
                          f.severity == FindingSeverity.issue
                              ? 'Issue'
                              : 'Warning',
                          style: TextStyle(
                            fontSize: 11,
                            color: f.severity == FindingSeverity.issue
                                ? _kIssueBadge
                                : _kWarningBadge,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(f.findingType.label,
                            style: const TextStyle(
                                color: _kSubtext, fontSize: 11)),
                      ],
                    ),
                    const SizedBox(height: 14),

                    _DrawerField(label: 'Current path', value: f.path),
                    const SizedBox(height: 10),
                    _DrawerField(
                        label: 'Proposed action',
                        value: _actionDescription(f)),

                    if (isRename) ...[
                      const SizedBox(height: 12),
                      const Text('New name',
                          style: TextStyle(
                              color: _kSubtext,
                              fontSize: 11,
                              fontWeight: FontWeight.w500)),
                      const SizedBox(height: 4),
                      TextField(
                        controller: _nameController,
                        style:
                            const TextStyle(color: _kText, fontSize: 12),
                        onChanged: widget.onDestinationChanged,
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 8),
                          filled: true,
                          fillColor: const Color(0xFF3C3C3C),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                            borderSide:
                                const BorderSide(color: _kDivider),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                            borderSide:
                                const BorderSide(color: _kDivider),
                          ),
                        ),
                      ),
                    ],

                    if (f.inferenceBasis.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      const Text('Why?',
                          style: TextStyle(
                              color: _kSubtext,
                              fontSize: 11,
                              fontWeight: FontWeight.w500)),
                      const SizedBox(height: 4),
                      Text(f.inferenceBasis,
                          style: const TextStyle(
                              color: _kText, fontSize: 12)),
                    ],

                    if (f.triggeredBy != null) ...[
                      const SizedBox(height: 12),
                      const Row(
                        children: [
                          Icon(Icons.account_tree,
                              size: 12, color: _kSubtext),
                          SizedBox(width: 4),
                          Text('Cascaded from parent finding',
                              style: TextStyle(
                                  color: _kSubtext, fontSize: 11)),
                        ],
                      ),
                    ],

                    // Current decision status
                    if (!isDefault) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(
                            accepted ? Icons.check_circle : Icons.cancel,
                            size: 12,
                            color: accepted ? _kSuccessBadge : _kSubtext,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            accepted
                                ? 'Explicitly accepted'
                                : 'Rejected — folder restored in target',
                            style: TextStyle(
                              fontSize: 11,
                              color: accepted ? _kSuccessBadge : _kSubtext,
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      const SizedBox(height: 12),
                      const Text(
                        'Applied by default — reject to revert',
                        style: TextStyle(color: _kSubtext, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Accept / Reject buttons
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: _kDivider))),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor:
                            rejected ? _kIssueBadge : _kSubtext,
                        side: BorderSide(
                            color: rejected ? _kIssueBadge : _kDivider),
                      ),
                      onPressed: widget.onReject,
                      child: const Text('Reject',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            accepted ? _kSuccessBadge : _kBlue,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: widget.onAccept,
                      child: Text(
                        accepted ? 'Accepted ✓' : 'Accept',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _actionDescription(RationalizeFinding f) => switch (f.action) {
        FindingAction.remove => 'Remove → Quarantine',
        FindingAction.rename => () {
            final dest =
                widget.destinationOverride ?? f.destination ?? '';
            final name =
                dest.isNotEmpty ? dest.split('/').last : '(suggested name)';
            return 'Rename to "$name"';
          }(),
        FindingAction.move => () {
            final dest =
                widget.destinationOverride ?? f.destination ?? '';
            return 'Move to $dest';
          }(),
      };
}

// ---------------------------------------------------------------------------
// _DrawerField
// ---------------------------------------------------------------------------

class _DrawerField extends StatelessWidget {
  const _DrawerField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: _kSubtext,
                fontSize: 11,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(color: _kText, fontSize: 12)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _BottomBar
// ---------------------------------------------------------------------------

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.pendingCount,
    required this.rejectedCount,
    required this.onApply,
    required this.onDone,
  });

  final int pendingCount;
  final int rejectedCount;
  final VoidCallback? onApply;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final hasChanges = pendingCount > 0;
    return Container(
      height: 44,
      color: _kPanelBg,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text(
            hasChanges
                ? '$pendingCount change${pendingCount != 1 ? 's' : ''} pending'
                : 'No changes pending',
            style: const TextStyle(color: _kSubtext, fontSize: 12),
          ),
          if (rejectedCount > 0) ...[
            const Text(' · ',
                style: TextStyle(color: _kSubtext, fontSize: 12)),
            Text('$rejectedCount rejected',
                style: const TextStyle(color: _kSubtext, fontSize: 12)),
          ],
          const Spacer(),
          const SizedBox(width: 8),
          if (hasChanges)
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _kBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onApply,
              child: Text(
                'Apply $pendingCount Change${pendingCount != 1 ? 's' : ''}',
                style: const TextStyle(fontSize: 12),
              ),
            )
          else
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _kSuccessBadge,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onDone,
              child: const Text('Done', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _FindingTypeBadge
// ---------------------------------------------------------------------------

class _FindingTypeBadge extends StatelessWidget {
  const _FindingTypeBadge({required this.type});

  final FindingType type;

  Color get _color => switch (type) {
        FindingType.emptyFolder => _kIssueBadge,
        FindingType.namingInconsistency => _kIssueBadge,
        FindingType.misplacedFile => _kWarningBadge,
        FindingType.excessiveNesting => _kWarningBadge,
      };

  String get _label => switch (type) {
        FindingType.emptyFolder => 'empty',
        FindingType.namingInconsistency => 'naming',
        FindingType.misplacedFile => 'misplaced',
        FindingType.excessiveNesting => 'nesting',
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: _color.withValues(alpha: 0.6)),
      ),
      child: Text(
        _label,
        style: TextStyle(
          color: _color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

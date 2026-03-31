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

// Finding action colours — defined as named constants so the palette is a
// one-line change once we validate legibility against real data.
const _kRemoveColor = Color(0xFFCD3131); // red — proposed removal
const _kRenameColor = Color(0xFFCCA700); // orange — proposed rename
const _kMoveColor = Color(0xFF4FC1FF); // blue — proposed move
const _kRenameTargetColor = Color(0xFF89D185); // green italic — in right panel

// ---------------------------------------------------------------------------
// Phase enum
// ---------------------------------------------------------------------------

enum _Phase {
  folderPicker,
  scanning,
  findings,
  executing,
  results,
}

// ---------------------------------------------------------------------------
// _TreeNode — one row in either the original or target tree
// ---------------------------------------------------------------------------

class _TreeNode {
  final String relativePath;
  final String name;
  final int depth;

  /// The finding on this exact path, if any.
  final RationalizeFinding? finding;

  /// True when the node is showing an accepted rename's new name.
  final bool isRenamedTarget;

  /// True when the node is showing an accepted move's destination.
  final bool isMovedTarget;

  const _TreeNode({
    required this.relativePath,
    required this.name,
    required this.depth,
    this.finding,
    this.isRenamedTarget = false,
    this.isMovedTarget = false,
  });
}

// ---------------------------------------------------------------------------
// RationalizeScreen
// ---------------------------------------------------------------------------

class RationalizeScreen extends StatefulWidget {
  const RationalizeScreen({super.key});

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

  // Findings state
  FindingsPayload? _payload;

  // Accept/Reject decisions: finding id → true (accepted) / false (rejected).
  // Absent key = unresolved. Unresolved = skipped at execution time.
  final Map<String, bool> _decisions = {};

  // User-overridden destination paths for rename/move: finding id → abs path.
  final Map<String, String> _destinationOverrides = {};

  // Currently open detail drawer.
  String? _drawerFindingId;

  // Execution
  ExecutionResult? _executionResult;

  // ---------------------------------------------------------------------------
  // Computed properties
  // ---------------------------------------------------------------------------

  Set<String> get _acceptedIds =>
      _decisions.entries.where((e) => e.value).map((e) => e.key).toSet();

  int get _unresolvedCount {
    final p = _payload;
    if (p == null) return 0;
    return p.findings.where((f) => !_decisions.containsKey(f.id)).length;
  }

  String _effectiveDestination(RationalizeFinding f) =>
      _destinationOverrides[f.id] ?? f.absoluteDestination ?? '';

  // ---------------------------------------------------------------------------
  // Tree building
  // ---------------------------------------------------------------------------

  /// Sorted list of nodes derived from all finding paths + their ancestors.
  List<_TreeNode> _buildOriginalTree(FindingsPayload payload) {
    final pathToFinding = <String, RationalizeFinding>{};
    for (final f in payload.findings) {
      pathToFinding[f.path] = f;
    }

    final allPaths = <String>{};
    for (final f in payload.findings) {
      var path = f.path;
      while (path.isNotEmpty) {
        allPaths.add(path);
        final slash = path.lastIndexOf('/');
        if (slash < 0) break;
        path = path.substring(0, slash);
      }
    }

    final sorted = allPaths.toList()..sort();
    return sorted.map((path) {
      final depth = path.split('/').length - 1;
      return _TreeNode(
        relativePath: path,
        name: path.split('/').last,
        depth: depth,
        finding: pathToFinding[path],
      );
    }).toList();
  }

  /// Compute the target tree by applying accepted actions to the original tree.
  List<_TreeNode> _buildTargetTree(FindingsPayload payload) {
    final accepted = _acceptedIds;
    final original = _buildOriginalTree(payload);

    // Paths that will be removed (accepted remove actions).
    final removedPaths = <String>{};
    for (final f in payload.findings) {
      if (accepted.contains(f.id) && f.action == FindingAction.remove) {
        removedPaths.add(f.path);
      }
    }

    final result = <_TreeNode>[];

    for (final node in original) {
      // Omit nodes under accepted removals.
      final isRemoved = removedPaths.any((rp) =>
          node.relativePath == rp || node.relativePath.startsWith('$rp/'));
      if (isRemoved) continue;

      final f = node.finding;
      if (f != null && accepted.contains(f.id)) {
        if (f.action == FindingAction.rename) {
          // Show with new name in green italic.
          final dest = _effectiveDestination(f);
          final newName =
              dest.isNotEmpty ? dest.split('/').last : node.name;
          result.add(_TreeNode(
            relativePath: node.relativePath,
            name: newName,
            depth: node.depth,
            finding: f,
            isRenamedTarget: true,
          ));
          continue;
        } else if (f.action == FindingAction.move) {
          // Omit from original location; will appear at destination below.
          continue;
        }
      }

      result.add(node);
    }

    // Add accepted move destinations.
    for (final f in payload.findings) {
      if (!accepted.contains(f.id) || f.action != FindingAction.move) continue;
      final dest = _effectiveDestination(f);
      if (dest.isEmpty) continue;

      final selectedFolder = payload.selectedFolder;
      final rel = dest.startsWith(selectedFolder)
          ? dest.substring(selectedFolder.length).replaceAll(RegExp(r'^/'), '')
          : dest.split('/').last;
      if (rel.isEmpty) continue;

      result.add(_TreeNode(
        relativePath: rel,
        name: rel.split('/').last,
        depth: rel.split('/').length - 1,
        finding: f,
        isMovedTarget: true,
      ));
    }

    result.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return result;
  }

  // ---------------------------------------------------------------------------
  // Accept / Reject
  // ---------------------------------------------------------------------------

  void _accept(String id) => setState(() {
        _decisions[id] = true;
        if (_drawerFindingId == id) _drawerFindingId = null;
      });

  void _reject(String id) => setState(() {
        _decisions[id] = false;
        if (_drawerFindingId == id) _drawerFindingId = null;
      });

  void _openDrawer(String id) => setState(() => _drawerFindingId = id);

  void _closeDrawer() => setState(() => _drawerFindingId = null);

  // ---------------------------------------------------------------------------
  // Scan
  // ---------------------------------------------------------------------------

  Future<void> _pickFolderAndScan() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty || !mounted) return;

    setState(() {
      _selectedFolder = path;
      _phase = _Phase.scanning;
      _foldersScanned = 0;
      _currentPath = '';
      _payload = null;
      _decisions.clear();
      _destinationOverrides.clear();
      _drawerFindingId = null;
      _executionResult = null;
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

  // ---------------------------------------------------------------------------
  // Execute
  // ---------------------------------------------------------------------------

  Future<void> _applyAccepted() async {
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

    final actions = _acceptedIds
        .map((id) => payload.findById(id))
        .whereType<RationalizeFinding>()
        .map((f) => ExecutionActionItem(
              findingId: f.id,
              action: f.action,
              absolutePath: f.absolutePath,
              absoluteDestination: f.action != FindingAction.remove
                  ? _effectiveDestination(f)
                  : null,
            ))
        .toList();

    final plan = ExecutionPlan(
      selectedFolder: folder,
      sessionId: sessionId,
      actions: actions,
    );

    setState(() => _phase = _Phase.executing);

    final result = await session.execute(plan);
    if (!mounted) return;

    setState(() {
      _executionResult = result;
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

  void _showContextMenu(
      BuildContext ctx, Offset globalPos, RationalizeFinding? finding) {
    final items = <PopupMenuEntry<String>>[
      if (finding != null) ...[
        PopupMenuItem(
          value: 'accept',
          child: Text(
            'Accept — ${_actionLabel(finding)}',
            style: const TextStyle(fontSize: 13),
          ),
        ),
        const PopupMenuItem(
          value: 'reject',
          child: Text('Reject this finding', style: TextStyle(fontSize: 13)),
        ),
        const PopupMenuDivider(),
      ],
      const PopupMenuItem(
        value: 'remove',
        enabled: false, // user-initiated removal: Iteration 4 (#46)
        child: Text('Mark for removal (coming soon)',
            style: TextStyle(fontSize: 13)),
      ),
    ];

    showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(
          globalPos.dx, globalPos.dy, globalPos.dx + 1, globalPos.dy + 1),
      color: const Color(0xFF2D2D30),
      items: items,
    ).then((value) {
      if (value == null || finding == null) return;
      if (value == 'accept') _accept(finding.id);
      if (value == 'reject') _reject(finding.id);
    });
  }

  String _actionLabel(RationalizeFinding f) => switch (f.action) {
        FindingAction.remove => 'Remove',
        FindingAction.rename => () {
            final dest = _effectiveDestination(f);
            final name = dest.isNotEmpty ? dest.split('/').last : '';
            return 'Rename to "$name"';
          }(),
        FindingAction.move => 'Move to ${f.destination ?? ''}',
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

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

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
        _Phase.executing => _buildExecuting(),
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
    final accepted = _acceptedIds;
    final drawerFinding = _drawerFindingId != null
        ? payload.findById(_drawerFindingId!)
        : null;

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Left panel — original state
                  Expanded(
                    child: _OriginalTreePanel(
                      nodes: originalNodes,
                      decisions: _decisions,
                      drawerFindingId: _drawerFindingId,
                      onNodeTap: (f) {
                        if (f != null) _openDrawer(f.id);
                      },
                      onNodeRightClick: _showContextMenu,
                    ),
                  ),
                  Container(width: 1, color: _kDivider),
                  // Right panel — target state
                  Expanded(
                    child: _TargetTreePanel(
                      nodes: targetNodes,
                      drawerFindingId: _drawerFindingId,
                      onNodeTap: (f) {
                        if (f != null) _openDrawer(f.id);
                      },
                    ),
                  ),
                ],
              ),
              // Detail drawer slides in over the right panel
              if (drawerFinding != null)
                _DetailDrawerOverlay(
                  finding: drawerFinding,
                  decision: _decisions[drawerFinding.id],
                  destinationOverride:
                      _destinationOverrides[drawerFinding.id],
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
          accepted: accepted.length,
          unresolved: _unresolvedCount,
          onApply: accepted.isNotEmpty ? _applyAccepted : null,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Phase: Executing
  // ---------------------------------------------------------------------------

  Widget _buildExecuting() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: _kBlue),
          SizedBox(height: 24),
          Text('Applying changes…',
              style: TextStyle(color: _kText, fontSize: 14)),
          SizedBox(height: 8),
          Text('Moving items to quarantine if needed.',
              style: TextStyle(color: _kSubtext, fontSize: 12)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Phase: Results
  // ---------------------------------------------------------------------------

  Widget _buildResults() {
    final result = _executionResult;
    if (result == null) {
      return const Center(
          child: Text('No result.', style: TextStyle(color: _kText)));
    }

    final allOk = result.failed == 0;
    return Center(
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              allOk
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_outlined,
              size: 48,
              color: allOk ? _kSuccessBadge : _kWarningBadge,
            ),
            const SizedBox(height: 16),
            Text(
              allOk
                  ? 'Changes applied successfully'
                  : '${result.failed} action${result.failed != 1 ? 's' : ''} failed',
              style: const TextStyle(
                  color: _kText,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '${result.succeeded} succeeded · '
              '${result.skipped} skipped · '
              '${result.failed} failed',
              style: const TextStyle(color: _kSubtext, fontSize: 13),
            ),
            if (result.succeeded > 0) ...[
              const SizedBox(height: 8),
              const Text(
                'Removed items quarantined at:\n~/.filesteward/quarantine/',
                textAlign: TextAlign.center,
                style: TextStyle(color: _kSubtext, fontSize: 12),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kText,
                    side: const BorderSide(color: _kDivider),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
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
                  onPressed: _rescan,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _OriginalTreePanel — left panel, colour-coded by action
// ---------------------------------------------------------------------------

class _OriginalTreePanel extends StatelessWidget {
  const _OriginalTreePanel({
    required this.nodes,
    required this.decisions,
    required this.drawerFindingId,
    required this.onNodeTap,
    required this.onNodeRightClick,
  });

  final List<_TreeNode> nodes;
  final Map<String, bool> decisions;
  final String? drawerFindingId;
  final void Function(RationalizeFinding?) onNodeTap;
  final void Function(BuildContext, Offset, RationalizeFinding?)
      onNodeRightClick;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _PanelHeader(
          title: 'Original',
          subtitle: '${nodes.length} folders',
        ),
        Expanded(
          child: ListView.builder(
            itemCount: nodes.length,
            itemBuilder: (ctx, i) {
              final node = nodes[i];
              final f = node.finding;

              Color? nameColor;
              if (f != null) {
                nameColor = switch (f.action) {
                  FindingAction.remove => _kRemoveColor,
                  FindingAction.rename => _kRenameColor,
                  FindingAction.move => _kMoveColor,
                };
              }

              return _TreeNodeRow(
                name: node.name,
                depth: node.depth,
                nameColor: nameColor,
                isItalic: false,
                decision: f != null ? decisions[f.id] : null,
                isFocused: f != null && f.id == drawerFindingId,
                onTap: f != null ? () => onNodeTap(f) : null,
                onSecondaryTap: (pos) => onNodeRightClick(ctx, pos, f),
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
  final void Function(RationalizeFinding?) onNodeTap;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) {
      return Column(
        children: [
          _PanelHeader(title: 'Target', subtitle: '0 folders'),
          const Expanded(
            child: Center(
              child: Text(
                'Accept actions to see the target state.',
                style: TextStyle(color: _kSubtext, fontSize: 13),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        _PanelHeader(
          title: 'Target',
          subtitle: '${nodes.length} folders',
        ),
        Expanded(
          child: ListView.builder(
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
                nameColor: nameColor,
                isItalic: isItalic,
                decision: null,
                isFocused: f != null && f.id == drawerFindingId,
                onTap: f != null ? () => onNodeTap(f) : null,
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
                  style:
                      const TextStyle(color: _kSubtext, fontSize: 11)),
            ],
          ),
        ),
        Container(height: 1, color: _kDivider),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _TreeNodeRow — one row in either panel
// ---------------------------------------------------------------------------

class _TreeNodeRow extends StatelessWidget {
  const _TreeNodeRow({
    required this.name,
    required this.depth,
    required this.nameColor,
    required this.isItalic,
    required this.decision,
    required this.isFocused,
    required this.onTap,
    required this.onSecondaryTap,
  });

  final String name;
  final int depth;
  final Color? nameColor;
  final bool isItalic;
  final bool? decision; // true=accepted, false=rejected, null=unresolved
  final bool isFocused;
  final VoidCallback? onTap;
  final void Function(Offset)? onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    final textColor = nameColor ?? _kText;
    final folderIconColor = nameColor ?? const Color(0xFF4FC1FF);

    return GestureDetector(
      onTap: onTap,
      onSecondaryTapUp: onSecondaryTap != null
          ? (d) => onSecondaryTap!(d.globalPosition)
          : null,
      child: Container(
        height: 26,
        color:
            isFocused ? _kBlue.withValues(alpha: 0.2) : Colors.transparent,
        padding: EdgeInsets.only(left: 12.0 + depth * 16.0, right: 8),
        child: Row(
          children: [
            Icon(Icons.folder, size: 14, color: folderIconColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontStyle:
                      isItalic ? FontStyle.italic : FontStyle.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (decision != null)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(
                  decision! ? Icons.check_circle : Icons.cancel,
                  size: 12,
                  color: decision! ? _kSuccessBadge : _kSubtext,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _DetailDrawerOverlay — slides in from the right over both panels
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

  static String _suggestedName(
      RationalizeFinding f, String? override) {
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
              decoration:
                  BoxDecoration(border: Border(bottom: BorderSide(color: _kDivider))),
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
                    // Type + severity row
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
                            style:
                                const TextStyle(color: _kSubtext, fontSize: 11)),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Path
                    _DrawerField(label: 'Current path', value: f.path),
                    const SizedBox(height: 10),

                    // Proposed action
                    _DrawerField(
                        label: 'Proposed action',
                        value: _actionDescription(f)),

                    // Rename field
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
                        style: const TextStyle(color: _kText, fontSize: 12),
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

                    // Inference basis
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

                    // Cascade indicator
                    if (f.triggeredBy != null) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: const [
                          Icon(Icons.account_tree,
                              size: 12, color: _kSubtext),
                          SizedBox(width: 4),
                          Text('Cascaded from parent finding',
                              style:
                                  TextStyle(color: _kSubtext, fontSize: 11)),
                        ],
                      ),
                    ],

                    // Current decision status
                    if (widget.decision != null) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(
                            accepted ? Icons.check_circle : Icons.cancel,
                            size: 12,
                            color:
                                accepted ? _kSuccessBadge : _kSubtext,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            accepted ? 'Accepted' : 'Rejected',
                            style: TextStyle(
                              fontSize: 11,
                              color:
                                  accepted ? _kSuccessBadge : _kSubtext,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text('— tap to change',
                              style: const TextStyle(
                                  color: _kSubtext, fontSize: 11)),
                        ],
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
                            color:
                                rejected ? _kIssueBadge : _kDivider),
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
                      child: const Text('Accept',
                          style: TextStyle(fontSize: 13)),
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
            final dest = widget.destinationOverride ?? f.destination ?? '';
            final name =
                dest.isNotEmpty ? dest.split('/').last : '(suggested name)';
            return 'Rename to "$name"';
          }(),
        FindingAction.move => () {
            final dest = widget.destinationOverride ?? f.destination ?? '';
            return 'Move to $dest';
          }(),
      };
}

// ---------------------------------------------------------------------------
// _DrawerField — labelled text field in the detail drawer
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
    required this.accepted,
    required this.unresolved,
    required this.onApply,
  });

  final int accepted;
  final int unresolved;
  final VoidCallback? onApply;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      color: _kPanelBg,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text(
            '$accepted accepted',
            style: TextStyle(
              color: accepted > 0 ? _kSuccessBadge : _kSubtext,
              fontSize: 12,
            ),
          ),
          if (unresolved > 0) ...[
            const Text(' · ',
                style: TextStyle(color: _kSubtext, fontSize: 12)),
            Text('$unresolved unresolved',
                style:
                    const TextStyle(color: _kSubtext, fontSize: 12)),
          ],
          const Spacer(),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  onApply != null ? _kBlue : _kDivider,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: onApply,
            child: Text(
              accepted > 0
                  ? 'Apply $accepted Change${accepted != 1 ? 's' : ''}'
                  : 'Apply Changes',
              style: const TextStyle(fontSize: 12),
            ),
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

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

// ---------------------------------------------------------------------------
// Phase enum
// ---------------------------------------------------------------------------

enum _Phase {
  folderPicker,
  scanning,
  findings,
  previewing,
  executing,
  results,
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
  final Set<String> _selectedIds = {};
  final Set<String> _dismissedIds = {};
  final Map<String, String> _destinationOverrides = {}; // id → abs path

  // Bidirectional selection
  String? _focusedFindingId;

  // Execution
  ExecutionResult? _executionResult;

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
      _selectedIds.clear();
      _dismissedIds.clear();
      _destinationOverrides.clear();
      _focusedFindingId = null;
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
  // Selection helpers
  // ---------------------------------------------------------------------------

  List<RationalizeFinding> get _visibleFindings {
    final p = _payload;
    if (p == null) return [];
    return p.findings.where((f) => !_dismissedIds.contains(f.id)).toList();
  }

  List<RationalizeFinding> _visibleFindingsOfType(FindingType type) =>
      _visibleFindings.where((f) => f.findingType == type).toList();

  bool _allCheckedForType(FindingType type) {
    final visible = _visibleFindingsOfType(type);
    if (visible.isEmpty) return false;
    return visible.every((f) => _selectedIds.contains(f.id));
  }

  bool _someCheckedForType(FindingType type) {
    final visible = _visibleFindingsOfType(type);
    return visible.any((f) => _selectedIds.contains(f.id)) &&
        !_allCheckedForType(type);
  }

  void _toggleGroupAll(FindingType type) {
    final visible = _visibleFindingsOfType(type);
    setState(() {
      if (_allCheckedForType(type)) {
        for (final f in visible) {
          _selectedIds.remove(f.id);
        }
      } else {
        for (final f in visible) {
          _selectedIds.add(f.id);
        }
      }
    });
  }

  void _toggleFinding(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _dismissFinding(String id) {
    setState(() {
      _dismissedIds.add(id);
      _selectedIds.remove(id);
      if (_focusedFindingId == id) _focusedFindingId = null;
    });
  }

  void _focusFinding(String id) {
    setState(() => _focusedFindingId = id);
  }

  // ---------------------------------------------------------------------------
  // Destination override
  // ---------------------------------------------------------------------------

  String _effectiveDestination(RationalizeFinding finding) {
    return _destinationOverrides[finding.id] ??
        finding.absoluteDestination ??
        '';
  }

  // ---------------------------------------------------------------------------
  // Preview & Execute
  // ---------------------------------------------------------------------------

  void _openPreview() {
    setState(() => _phase = _Phase.previewing);
  }

  void _closePreview() {
    setState(() => _phase = _Phase.findings);
  }

  Future<void> _applySelected() async {
    final session = _session;
    final payload = _payload;
    final folder = _selectedFolder;
    if (session == null || payload == null || folder == null) return;

    // Build session ID from current time (matches Rust format YYYY-MM-DDTHH-MM-SS)
    final now = DateTime.now().toUtc();
    final sessionId =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}T'
        '${now.hour.toString().padLeft(2, '0')}-'
        '${now.minute.toString().padLeft(2, '0')}-'
        '${now.second.toString().padLeft(2, '0')}';

    final actions = _selectedIds
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
  // Helpers
  // ---------------------------------------------------------------------------

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: _kIssueBadge,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

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

  Widget _buildBody() {
    return switch (_phase) {
      _Phase.folderPicker => _buildFolderPicker(),
      _Phase.scanning => _buildScanning(),
      _Phase.findings => _buildFindingsView(),
      _Phase.previewing => _buildPreviewView(),
      _Phase.executing => _buildExecuting(),
      _Phase.results => _buildResults(),
    };
  }

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
          const Text(
            'Choose a folder to rationalize',
            style: TextStyle(color: _kText, fontSize: 16),
          ),
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
            Text(
              'Scanning folder structure…',
              style: const TextStyle(color: _kText, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              '$_foldersScanned folders scanned',
              style: const TextStyle(color: _kSubtext, fontSize: 12),
            ),
            if (_currentPath.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                _currentPath,
                style:
                    const TextStyle(color: _kSubtext, fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Phase: Findings two-panel view
  // ---------------------------------------------------------------------------

  Widget _buildFindingsView() {
    final payload = _payload!;
    final selectedCount = _selectedIds.length;

    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left: findings panel
              SizedBox(
                width: 420,
                child: _FindingsPanel(
                  payload: payload,
                  visibleFindings: _visibleFindings,
                  selectedIds: _selectedIds,
                  focusedId: _focusedFindingId,
                  destinationOverrides: _destinationOverrides,
                  onToggle: _toggleFinding,
                  onDismiss: _dismissFinding,
                  onFocus: _focusFinding,
                  onGroupAllToggle: _toggleGroupAll,
                  isAllChecked: _allCheckedForType,
                  isSomeChecked: _someCheckedForType,
                  onDestinationChanged: (id, path) => setState(
                    () => _destinationOverrides[id] = path,
                  ),
                ),
              ),
              Container(width: 1, color: _kDivider),
              // Right: folder tree
              Expanded(
                child: _TreePanel(
                  payload: payload,
                  selectedIds: _selectedIds,
                  dismissedIds: _dismissedIds,
                  focusedId: _focusedFindingId,
                  onFocus: _focusFinding,
                ),
              ),
            ],
          ),
        ),
        Container(height: 1, color: _kDivider),
        _BottomBar(
          selectedCount: selectedCount,
          totalVisible: _visibleFindings.length,
          onPreview: selectedCount > 0 ? _openPreview : null,
          onApply: selectedCount > 0 ? _applySelected : null,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Phase: Preview
  // ---------------------------------------------------------------------------

  Widget _buildPreviewView() {
    final payload = _payload!;
    final selected = _selectedIds
        .map((id) => payload.findById(id))
        .whereType<RationalizeFinding>()
        .toList();

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Preview Changes',
                  style: TextStyle(
                      color: _kText,
                      fontSize: 18,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  '${selected.length} action${selected.length != 1 ? 's' : ''} will be applied. '
                  'Removed items are moved to quarantine — nothing is permanently deleted.',
                  style:
                      const TextStyle(color: _kSubtext, fontSize: 13),
                ),
                const SizedBox(height: 24),
                ...selected.map((f) => _PreviewRow(
                      finding: f,
                      effectiveDestination: _effectiveDestination(f),
                    )),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _kPanelBg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: _kDivider),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.archive_outlined,
                          color: _kSubtext, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Quarantine: ~/.filesteward/quarantine/',
                          style: const TextStyle(
                              color: _kSubtext, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(height: 1, color: _kDivider),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _closePreview,
                child: const Text('Cancel',
                    style: TextStyle(color: _kSubtext)),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kBlue,
                  foregroundColor: Colors.white,
                ),
                onPressed: _applySelected,
                child: Text(
                    'Apply ${_selectedIds.length} Change${_selectedIds.length != 1 ? 's' : ''}'),
              ),
            ],
          ),
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
          Text(
            'Applying changes…',
            style: TextStyle(color: _kText, fontSize: 14),
          ),
          SizedBox(height: 8),
          Text(
            'Moving items to quarantine if needed.',
            style: TextStyle(color: _kSubtext, fontSize: 12),
          ),
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
              allOk ? Icons.check_circle_outline : Icons.warning_amber_outlined,
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
              Text(
                'Removed items quarantined at:\n~/.filesteward/quarantine/',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _kSubtext, fontSize: 12),
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
// _FindingsPanel — left panel
// ---------------------------------------------------------------------------

class _FindingsPanel extends StatelessWidget {
  const _FindingsPanel({
    required this.payload,
    required this.visibleFindings,
    required this.selectedIds,
    required this.focusedId,
    required this.destinationOverrides,
    required this.onToggle,
    required this.onDismiss,
    required this.onFocus,
    required this.onGroupAllToggle,
    required this.isAllChecked,
    required this.isSomeChecked,
    required this.onDestinationChanged,
  });

  final FindingsPayload payload;
  final List<RationalizeFinding> visibleFindings;
  final Set<String> selectedIds;
  final String? focusedId;
  final Map<String, String> destinationOverrides;
  final void Function(String id) onToggle;
  final void Function(String id) onDismiss;
  final void Function(String id) onFocus;
  final void Function(FindingType type) onGroupAllToggle;
  final bool Function(FindingType type) isAllChecked;
  final bool Function(FindingType type) isSomeChecked;
  final void Function(String id, String path) onDestinationChanged;

  static const _groupOrder = [
    FindingType.emptyFolder,
    FindingType.namingInconsistency,
    FindingType.misplacedFile,
    FindingType.excessiveNesting,
  ];

  @override
  Widget build(BuildContext context) {
    if (visibleFindings.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No findings. Your folder structure looks good!',
            textAlign: TextAlign.center,
            style: TextStyle(color: _kSubtext, fontSize: 13),
          ),
        ),
      );
    }

    final groups = <FindingType, List<RationalizeFinding>>{};
    for (final type in _groupOrder) {
      final items =
          visibleFindings.where((f) => f.findingType == type).toList();
      if (items.isNotEmpty) groups[type] = items;
    }

    return Column(
      children: [
        // Header
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: _kPanelBg,
          alignment: Alignment.centerLeft,
          child: Text(
            '${visibleFindings.length} finding${visibleFindings.length != 1 ? 's' : ''}',
            style:
                const TextStyle(color: _kSubtext, fontSize: 11),
          ),
        ),
        Container(height: 1, color: _kDivider),
        // Groups
        Expanded(
          child: ListView(
            children: [
              for (final type in _groupOrder)
                if (groups.containsKey(type)) ...[
                  _FindingGroupHeader(
                    type: type,
                    count: groups[type]!.length,
                    allChecked: isAllChecked(type),
                    someChecked: isSomeChecked(type),
                    onToggleAll: () => onGroupAllToggle(type),
                  ),
                  for (final finding in groups[type]!)
                    _FindingRow(
                      finding: finding,
                      isSelected: selectedIds.contains(finding.id),
                      isFocused: focusedId == finding.id,
                      overridePath: destinationOverrides[finding.id],
                      onToggle: () => onToggle(finding.id),
                      onDismiss: () => onDismiss(finding.id),
                      onTap: () => onFocus(finding.id),
                      onDestinationChanged: (path) =>
                          onDestinationChanged(finding.id, path),
                    ),
                ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _FindingGroupHeader
// ---------------------------------------------------------------------------

class _FindingGroupHeader extends StatelessWidget {
  const _FindingGroupHeader({
    required this.type,
    required this.count,
    required this.allChecked,
    required this.someChecked,
    required this.onToggleAll,
  });

  final FindingType type;
  final int count;
  final bool allChecked;
  final bool someChecked;
  final VoidCallback onToggleAll;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onToggleAll,
      child: Container(
        height: 30,
        color: const Color(0xFF2D2D30),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            _TriStateCheckbox(
              checked: allChecked,
              indeterminate: someChecked,
              onTap: onToggleAll,
            ),
            const SizedBox(width: 8),
            _FindingTypeBadge(type: type),
            const SizedBox(width: 8),
            Text(
              type.label,
              style: const TextStyle(
                  color: _kText,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              '$count',
              style: const TextStyle(color: _kSubtext, fontSize: 11),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _FindingRow
// ---------------------------------------------------------------------------

class _FindingRow extends StatefulWidget {
  const _FindingRow({
    required this.finding,
    required this.isSelected,
    required this.isFocused,
    required this.overridePath,
    required this.onToggle,
    required this.onDismiss,
    required this.onTap,
    required this.onDestinationChanged,
  });

  final RationalizeFinding finding;
  final bool isSelected;
  final bool isFocused;
  final String? overridePath;
  final VoidCallback onToggle;
  final VoidCallback onDismiss;
  final VoidCallback onTap;
  final void Function(String path) onDestinationChanged;

  @override
  State<_FindingRow> createState() => _FindingRowState();
}

class _FindingRowState extends State<_FindingRow> {
  bool _showOverrideInput = false;
  final _overrideController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _overrideController.text =
        widget.overridePath ?? widget.finding.absoluteDestination ?? '';
  }

  @override
  void dispose() {
    _overrideController.dispose();
    super.dispose();
  }

  String get _proposedAction {
    switch (widget.finding.action) {
      case FindingAction.remove:
        return 'Remove → Quarantine';
      case FindingAction.rename:
        final dest = widget.overridePath ??
            widget.finding.destination ??
            '';
        final name = dest.split('/').last;
        return 'Rename to "$name"';
      case FindingAction.move:
        final dest = widget.overridePath ??
            widget.finding.destination ??
            '';
        return 'Move to $dest';
    }
  }

  bool get _canOverrideDestination =>
      widget.finding.action != FindingAction.remove;

  @override
  Widget build(BuildContext context) {
    final isFocused = widget.isFocused;
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        color: isFocused
            ? _kBlue.withValues(alpha: 0.15)
            : Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TriStateCheckbox(
                    checked: widget.isSelected,
                    indeterminate: false,
                    onTap: widget.onToggle,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Name + dependency indicator
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.finding.displayName,
                                style: const TextStyle(
                                    color: _kText, fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (widget.finding.isDependent)
                              Padding(
                                padding:
                                    const EdgeInsets.only(left: 4),
                                child: Text(
                                  '↳ cascade',
                                  style: const TextStyle(
                                      color: _kSubtext, fontSize: 10),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        // Relative path
                        Text(
                          widget.finding.path,
                          style: const TextStyle(
                              color: _kSubtext, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        // Proposed action
                        Text(
                          _proposedAction,
                          style: const TextStyle(
                              color: _kSubtext, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                        // Destination override link
                        if (_canOverrideDestination) ...[
                          const SizedBox(height: 4),
                          GestureDetector(
                            onTap: () => setState(
                                () => _showOverrideInput = !_showOverrideInput),
                            child: Text(
                              _showOverrideInput
                                  ? 'Cancel override'
                                  : 'Choose location…',
                              style: const TextStyle(
                                  color: _kBlue,
                                  fontSize: 11,
                                  decoration: TextDecoration.underline),
                            ),
                          ),
                        ],
                        // Inline override input
                        if (_showOverrideInput)
                          _DestinationOverrideInput(
                            controller: _overrideController,
                            onChanged: widget.onDestinationChanged,
                          ),
                      ],
                    ),
                  ),
                  // Dismiss button
                  GestureDetector(
                    onTap: widget.onDismiss,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 8, top: 2),
                      child: Icon(Icons.close,
                          size: 14, color: _kSubtext),
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: _kDivider.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _DestinationOverrideInput
// ---------------------------------------------------------------------------

class _DestinationOverrideInput extends StatefulWidget {
  const _DestinationOverrideInput({
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final void Function(String path) onChanged;

  @override
  State<_DestinationOverrideInput> createState() =>
      _DestinationOverrideInputState();
}

class _DestinationOverrideInputState
    extends State<_DestinationOverrideInput> {
  bool? _exists; // null = unchecked, true = exists, false = will be created

  @override
  void initState() {
    super.initState();
    _checkPath(widget.controller.text);
    widget.controller.addListener(_handleChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleChange);
    super.dispose();
  }

  void _handleChange() {
    _checkPath(widget.controller.text);
    widget.onChanged(widget.controller.text.trim());
  }

  void _checkPath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      if (mounted) setState(() => _exists = null);
      return;
    }
    final exists = Directory(trimmed).existsSync();
    if (mounted) setState(() => _exists = exists);
  }

  Future<void> _browse() async {
    final path = await getDirectoryPath();
    if (path != null && path.isNotEmpty) {
      widget.controller.text = path;
      widget.onChanged(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  style: const TextStyle(
                      color: _kText, fontSize: 11),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 6),
                    filled: true,
                    fillColor: const Color(0xFF3C3C3C),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: const BorderSide(
                          color: _kDivider),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide:
                          const BorderSide(color: _kDivider),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: _kText,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _browse,
                child: const Text('Browse',
                    style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          if (_exists != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 8,
                  color: _exists! ? _kSuccessBadge : _kWarningBadge,
                ),
                const SizedBox(width: 4),
                Text(
                  _exists! ? 'Folder exists' : 'Will be created',
                  style: TextStyle(
                    fontSize: 10,
                    color: _exists! ? _kSuccessBadge : _kWarningBadge,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _TreePanel — right panel (Finder-style folder tree)
// ---------------------------------------------------------------------------

class _TreePanel extends StatelessWidget {
  const _TreePanel({
    required this.payload,
    required this.selectedIds,
    required this.dismissedIds,
    required this.focusedId,
    required this.onFocus,
  });

  final FindingsPayload payload;
  final Set<String> selectedIds;
  final Set<String> dismissedIds;
  final String? focusedId;
  final void Function(String id) onFocus;

  @override
  Widget build(BuildContext context) {
    // Build a map: relative_path → list of (non-dismissed) finding IDs
    final pathFindings = <String, List<RationalizeFinding>>{};
    for (final f in payload.findings) {
      if (!dismissedIds.contains(f.id)) {
        pathFindings.putIfAbsent(f.path, () => []).add(f);
      }
    }

    // Collect all unique folder paths from findings
    final allPaths = <String>{};
    for (final f in payload.findings) {
      final parts = f.path.split('/');
      for (int i = 1; i <= parts.length; i++) {
        allPaths.add(parts.sublist(0, i).join('/'));
      }
    }
    final sortedPaths = allPaths.toList()..sort();

    return Column(
      children: [
        // Column headers
        Container(
          height: 32,
          color: _kPanelBg,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              const Expanded(
                flex: 5,
                child: Text('Name',
                    style:
                        TextStyle(color: _kSubtext, fontSize: 11)),
              ),
              const SizedBox(
                width: 120,
                child: Text('Findings',
                    style: TextStyle(
                        color: _kSubtext, fontSize: 11)),
              ),
            ],
          ),
        ),
        Container(height: 1, color: _kDivider),
        // Tree rows
        Expanded(
          child: ListView.builder(
            itemCount: sortedPaths.length,
            itemBuilder: (context, index) {
              final path = sortedPaths[index];
              final depth =
                  path.split('/').length - 1;
              final name = path.split('/').last;
              final findings = pathFindings[path] ?? [];
              final focusedHere = findings.any(
                  (f) => f.id == focusedId);

              return _TreeRow(
                name: name,
                depth: depth,
                findings: findings,
                isFocused: focusedHere,
                hasDescendantFindings:
                    pathFindings.keys.any((k) =>
                        k.startsWith('$path/') &&
                        pathFindings[k]!.isNotEmpty),
                onTap: findings.isNotEmpty
                    ? () => onFocus(findings.first.id)
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _TreeRow
// ---------------------------------------------------------------------------

class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.name,
    required this.depth,
    required this.findings,
    required this.isFocused,
    required this.hasDescendantFindings,
    this.onTap,
  });

  final String name;
  final int depth;
  final List<RationalizeFinding> findings;
  final bool isFocused;
  final bool hasDescendantFindings;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 26,
        color: isFocused ? _kBlue.withValues(alpha: 0.15) : Colors.transparent,
        padding: EdgeInsets.only(left: 12.0 + depth * 16),
        child: Row(
          children: [
            const Icon(Icons.folder, size: 14, color: Color(0xFF4FC1FF)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                style:
                    const TextStyle(color: _kText, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (hasDescendantFindings && findings.isEmpty)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Text('↓',
                    style: TextStyle(
                        color: _kSubtext, fontSize: 10)),
              ),
            // Badges for findings on this node
            for (final f in findings)
              Padding(
                padding: const EdgeInsets.only(right: 3),
                child: _FindingTypeBadge(type: f.findingType, small: true),
              ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _BottomBar
// ---------------------------------------------------------------------------

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.selectedCount,
    required this.totalVisible,
    required this.onPreview,
    required this.onApply,
  });

  final int selectedCount;
  final int totalVisible;
  final VoidCallback? onPreview;
  final VoidCallback? onApply;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      color: _kPanelBg,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Text(
            selectedCount > 0
                ? '$selectedCount of $totalVisible selected'
                : '$totalVisible finding${totalVisible != 1 ? 's' : ''}',
            style: const TextStyle(color: _kSubtext, fontSize: 12),
          ),
          const Spacer(),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: _kText),
            onPressed: onPreview,
            child: const Text('Preview Changes',
                style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  onApply != null ? _kBlue : _kDivider,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: onApply,
            child: Text(
              selectedCount > 0
                  ? 'Apply Selected ($selectedCount)'
                  : 'Apply Selected',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _PreviewRow
// ---------------------------------------------------------------------------

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({
    required this.finding,
    required this.effectiveDestination,
  });

  final RationalizeFinding finding;
  final String effectiveDestination;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _kPanelBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _kDivider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FindingTypeBadge(type: finding.findingType),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(finding.displayName,
                    style: const TextStyle(
                        color: _kText,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(
                  _actionSummary,
                  style:
                      const TextStyle(color: _kSubtext, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String get _actionSummary {
    switch (finding.action) {
      case FindingAction.remove:
        return '→ Move to quarantine';
      case FindingAction.rename:
        final name = effectiveDestination.split('/').last;
        return '→ Rename to "$name"';
      case FindingAction.move:
        return '→ Move to $effectiveDestination';
    }
  }
}

// ---------------------------------------------------------------------------
// _FindingTypeBadge
// ---------------------------------------------------------------------------

class _FindingTypeBadge extends StatelessWidget {
  const _FindingTypeBadge({required this.type, this.small = false});

  final FindingType type;
  final bool small;

  Color get _color {
    switch (type) {
      case FindingType.emptyFolder:
        return _kIssueBadge;
      case FindingType.namingInconsistency:
        return _kIssueBadge;
      case FindingType.misplacedFile:
        return _kWarningBadge;
      case FindingType.excessiveNesting:
        return _kWarningBadge;
    }
  }

  String get _label {
    switch (type) {
      case FindingType.emptyFolder:
        return small ? 'E' : 'empty';
      case FindingType.namingInconsistency:
        return small ? 'N' : 'naming';
      case FindingType.misplacedFile:
        return small ? 'M' : 'misplaced';
      case FindingType.excessiveNesting:
        return small ? 'D' : 'nesting';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: small ? 4 : 6,
          vertical: small ? 1 : 2),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: _color.withValues(alpha: 0.6)),
      ),
      child: Text(
        _label,
        style: TextStyle(
          color: _color,
          fontSize: small ? 9 : 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _TriStateCheckbox — custom visible checkbox for dark backgrounds
// ---------------------------------------------------------------------------

class _TriStateCheckbox extends StatelessWidget {
  const _TriStateCheckbox({
    required this.checked,
    required this.indeterminate,
    required this.onTap,
  });

  final bool checked;
  final bool indeterminate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: (checked || indeterminate) ? _kBlue : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: (checked || indeterminate)
                ? _kBlue
                : const Color(0xFF6E6E6E),
            width: 1.5,
          ),
        ),
        child: Center(
          child: indeterminate
              ? Container(
                  width: 8,
                  height: 2,
                  color: Colors.white,
                )
              : checked
                  ? const Icon(Icons.check,
                      size: 11, color: Colors.white)
                  : null,
        ),
      ),
    );
  }
}

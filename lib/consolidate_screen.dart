import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'app_version.dart';
import 'consolidate_build_confirm_screen.dart';
import 'consolidate_models.dart';
import 'consolidate_scan1_screen.dart';
import 'consolidate_scan2_screen.dart';
import 'consolidate_service.dart';

// ---------------------------------------------------------------------------
// Screen phases
// ---------------------------------------------------------------------------

enum _Phase {
  sourceSelection,
  scan1, // structure scan + file-type exclusion choices
  scan2, // content scan + collision/ambiguity review
  buildConfirm, // final review + build execution
}

// ---------------------------------------------------------------------------
// ConsolidateScreen — top-level orchestrator
// ---------------------------------------------------------------------------

class ConsolidateScreen extends StatefulWidget {
  const ConsolidateScreen({super.key});

  @override
  State<ConsolidateScreen> createState() => _ConsolidateScreenState();
}

class _ConsolidateScreenState extends State<ConsolidateScreen> {
  final _service = const ConsolidateService();

  _Phase _phase = _Phase.sourceSelection;

  // Source selection
  final List<String> _folders = [];

  // Target
  String? _targetParentPath;
  final TextEditingController _targetNameController = TextEditingController();
  bool _targetManuallySet = false;

  String? get _resolvedTargetPath {
    final parent = _targetParentPath;
    final name = _targetNameController.text.trim();
    if (parent == null || name.isEmpty) return null;
    return '$parent/$name';
  }

  // Results passed between phases.
  List<String> _excludedExtensions = [];
  List<String> _excludedFolders = [];
  List<String> _overriddenPaths = [];
  ContentScanComplete? _scanResult;
  Map<String, String> _collisionOverrides = {};

  // Error from source selection.
  String? _errorMessage;

  @override
  void dispose() {
    _targetNameController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Source selection helpers
  // ---------------------------------------------------------------------------

  bool _isDangerousPath(String path) {
    final normalized =
        path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final parts = normalized.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return true;
    if (parts.length == 1) return true;
    if (parts.length == 2 && parts[0] == 'Volumes') return true;
    const systemDirs = {
      'System',
      'Library',
      'Applications',
      'bin',
      'sbin',
      'usr',
      'etc',
      'var',
      'private',
      'cores',
      'opt',
    };
    if (parts.length == 1 && systemDirs.contains(parts[0])) return true;
    return false;
  }

  void _autoPopulateTarget(String folderPath) {
    if (_targetManuallySet) return;
    final parts = folderPath.split('/');
    final parent =
        parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '/';
    final name = '${parts.last}_consolidated';
    setState(() {
      _targetParentPath = parent;
      _targetNameController.text = name;
    });
  }

  Future<void> _addFolder() async {
    final paths = await getDirectoryPaths();
    if (paths.isEmpty) return;

    bool addedFirst = false;
    for (final path in paths) {
      if (path == null || path.isEmpty) continue;
      if (_isDangerousPath(path)) {
        _showVolumeRootError();
        continue;
      }
      if (_folders.contains(path)) continue;
      setState(() {
        _folders.add(path);
      });
      if (!addedFirst && _folders.length == 1) {
        _autoPopulateTarget(path);
        addedFirst = true;
      }
    }
    // Auto-populate target from first added folder if not yet set.
    if (!addedFirst && !_targetManuallySet && _folders.isNotEmpty) {
      _autoPopulateTarget(_folders.first);
    }
  }

  Future<void> _pickTargetParent() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return;
    setState(() {
      _targetParentPath = path;
      _targetManuallySet = true;
    });
  }

  void _showVolumeRootError() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Please select a specific folder, not a whole drive or volume root.',
        ),
        duration: Duration(seconds: 4),
      ),
    );
  }

  void _removeFolder(int index) {
    setState(() => _folders.removeAt(index));
  }

  bool get _canStart =>
      _folders.length >= 2 && _resolvedTargetPath != null;

  // ---------------------------------------------------------------------------
  // Phase transitions
  // ---------------------------------------------------------------------------

  void _startScan1() {
    setState(() {
      _phase = _Phase.scan1;
      _errorMessage = null;
      _excludedExtensions = [];
      _excludedFolders = [];
      _overriddenPaths = [];
      _scanResult = null;
      _collisionOverrides = {};
    });
  }

  void _onScan1Proceed({
    required List<String> excludedExtensions,
    required List<String> excludedFolders,
    required List<String> overriddenPaths,
  }) {
    setState(() {
      _excludedExtensions = excludedExtensions;
      _excludedFolders = excludedFolders;
      _overriddenPaths = overriddenPaths;
      _phase = _Phase.scan2;
    });
  }

  void _onScan2Proceed(
    ContentScanComplete result,
    Map<String, String> collisionOverrides,
  ) {
    setState(() {
      _scanResult = result;
      _collisionOverrides = collisionOverrides;
      _phase = _Phase.buildConfirm;
    });
  }

  void _goBackToSourceSelection() {
    setState(() => _phase = _Phase.sourceSelection);
  }

  void _goBackToScan1() {
    setState(() => _phase = _Phase.scan1);
  }

  void _goBackToScan2() {
    setState(() => _phase = _Phase.scan2);
  }

  // ---------------------------------------------------------------------------
  // Root build
  // ---------------------------------------------------------------------------

  int get _currentStep => switch (_phase) {
        _Phase.sourceSelection => 0,
        _Phase.scan1 => 1,
        _Phase.scan2 => 2,
        _Phase.buildConfirm => 3,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FileSteward'),
        automaticallyImplyLeading: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text(
              'v$kAppVersion',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: _StepProgressBar(currentStep: _currentStep),
        ),
      ),
      body: switch (_phase) {
        _Phase.sourceSelection => _buildSourceSelection(),
        _Phase.scan1 => ConsolidateScan1Screen(
            sourceFolders: _folders,
            service: _service,
            onProceed: _onScan1Proceed,
            onBack: _goBackToSourceSelection,
          ),
        _Phase.scan2 => ConsolidateScan2Screen(
            sourceFolders: _folders,
            excludedExtensions: _excludedExtensions,
            excludedFolders: _excludedFolders,
            overriddenPaths: _overriddenPaths,
            service: _service,
            onProceed: _onScan2Proceed,
            onBack: _goBackToScan1,
          ),
        _Phase.buildConfirm => ConsolidateBuildConfirmScreen(
            result: _scanResult!,
            collisionOverrides: _collisionOverrides,
            sourceFolders: _folders,
            targetPath: _resolvedTargetPath!,
            service: _service,
            onComplete: _onBuildCompleteAndClose,
            onBack: _goBackToScan2,
          ),
      },
    );
  }

  void _onBuildCompleteAndClose(int filesCopied, String targetPath) {
    // Called from the Done button in the build confirm screen.
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$filesCopied files consolidated to ${targetPath.split('/').last}'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Phase: source selection
  // ---------------------------------------------------------------------------

  Widget _buildSourceSelection() {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_errorMessage != null)
                  _ErrorBanner(message: _errorMessage!),
                const _SectionHeader(
                  title: 'Folders to Consolidate',
                  subtitle:
                      'Add two or more peer folders. Contents will be merged '
                      'into a single output — duplicates removed, conflicts renamed.',
                ),
                const SizedBox(height: 8),
                ..._folders.asMap().entries.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _SourceTile(
                        path: e.value,
                        label: 'Folder ${e.key + 1}',
                        color: _folderColor(e.key),
                        onRemove: () => _removeFolder(e.key),
                      ),
                    )),
                OutlinedButton.icon(
                  onPressed: _addFolder,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Folder…'),
                ),
                const SizedBox(height: 16),
                const _SectionHeader(
                  title: 'Output Location',
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
                              ? _targetParentPath!.split('/').last
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
                        onChanged: (_) => setState(() {
                          _targetManuallySet = true;
                        }),
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
                if (_folders.length < 2 && _folders.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Add at least one more folder to consolidate.',
                    style: TextStyle(fontSize: 12, color: Colors.orange[700]),
                  ),
                ],
              ],
            ),
          ),
        ),
        _BottomBar(
          child: FilledButton.icon(
            onPressed: _canStart ? _startScan1 : null,
            icon: const Icon(Icons.search),
            label: const Text('Scan Folder Structure'),
          ),
        ),
      ],
    );
  }

  Color _folderColor(int index) {
    const colors = [
      Color(0xFF0E70C0), // blue
      Color(0xFF0A7764), // teal
      Color(0xFF7B3FB5), // purple
      Color(0xFFB85C00), // amber
    ];
    return colors[index % colors.length];
  }
}

// ---------------------------------------------------------------------------
// Step progress bar
// ---------------------------------------------------------------------------

class _StepProgressBar extends StatelessWidget {
  const _StepProgressBar({required this.currentStep});

  final int currentStep;

  static const _steps = ['Select', 'Filter', 'Scan', 'Build'];

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Row(
        children: List.generate(_steps.length * 2 - 1, (i) {
          // Odd indices are connector lines between steps.
          if (i.isOdd) {
            final stepIndex = i ~/ 2;
            final done = stepIndex < currentStep;
            return Expanded(
              child: Container(
                height: 2,
                color: done ? accent : Colors.grey.shade300,
              ),
            );
          }
          final stepIndex = i ~/ 2;
          final done = stepIndex < currentStep;
          final active = stepIndex == currentStep;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done || active ? accent : Colors.grey.shade300,
                ),
                child: Center(
                  child: done
                      ? const Icon(Icons.check, size: 14, color: Colors.white)
                      : Text(
                          '${stepIndex + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: active ? Colors.white : Colors.grey.shade500,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _steps[stepIndex],
                style: TextStyle(
                  fontSize: 10,
                  fontWeight:
                      active ? FontWeight.w600 : FontWeight.normal,
                  color: active ? accent : Colors.grey.shade500,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reusable helper widgets
// ---------------------------------------------------------------------------

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
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(subtitle, style: TextStyle(fontSize: 13, color: Colors.grey[600])),
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

  String get _leafName => path.split('/').last;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withAlpha(30),
          child: Icon(Icons.folder, color: color, size: 20),
        ),
        title: Text(_leafName,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          path,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      color: color,
                      fontWeight: FontWeight.w600)),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: onRemove,
              tooltip: 'Remove',
            ),
          ],
        ),
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
                style: TextStyle(color: Colors.red[800], fontSize: 13)),
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
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: Colors.grey[200]!)),
      ),
      child: SizedBox(
        width: double.infinity,
        child: child,
      ),
    );
  }
}

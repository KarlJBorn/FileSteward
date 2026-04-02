import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'consolidate_models.dart';
import 'consolidate_service.dart';

// ---------------------------------------------------------------------------
// Screen phases
// ---------------------------------------------------------------------------

enum _Phase {
  sourceSelection,
  scanning,
  review,
  building,
  result,
}

enum _SourceScanStatus { waiting, scanning, done }

class _SourceScanState {
  _SourceScanStatus status;
  int filesScanned;
  _SourceScanState({required this.status, this.filesScanned = 0});
}

// ---------------------------------------------------------------------------
// Review state: Keep (default) or Skip per unique file
// ---------------------------------------------------------------------------

class _ReviewItem {
  final String secondaryPath;
  final UniqueFile file;
  bool keep = true;

  _ReviewItem({
    required this.secondaryPath,
    required this.file,
  });
}

// ---------------------------------------------------------------------------
// ConsolidateScreen
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
  String? _primaryPath;
  final List<String> _secondaryPaths = [];

  // Scan
  String _scanProgressSource = '';
  List<String> _scanSources = []; // primary + secondaries in order
  Map<String, _SourceScanState> _scanStates = {};
  String? _sessionId;
  List<SecondaryDiff> _diffs = [];

  // Review
  List<_ReviewItem> _reviewItems = [];

  // Build
  int _buildFilesTotal = 0;
  int _buildFilesDone = 0;
  String? _targetPath;

  // Result
  int _filesCopied = 0;

  // Error
  String? _errorMessage;

  // ---------------------------------------------------------------------------
  // Source selection helpers
  // ---------------------------------------------------------------------------

  /// Returns true if [path] is a volume root or system directory that should
  /// never be scanned (e.g. /, /Volumes/Macintosh HD, /System, /Users).
  bool _isDangerousPath(String path) {
    final normalized = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final parts = normalized.split('/').where((p) => p.isNotEmpty).toList();
    // Root itself, or a top-level system directory.
    if (parts.isEmpty) return true;
    if (parts.length == 1) return true; // e.g. /Volumes
    // /Volumes/<disk name> — volume roots.
    if (parts.length == 2 && parts[0] == 'Volumes') return true;
    // Common macOS system directories at depth 1.
    const systemDirs = {
      'System', 'Library', 'Applications', 'bin', 'sbin',
      'usr', 'etc', 'var', 'private', 'cores', 'opt',
    };
    if (parts.length == 1 && systemDirs.contains(parts[0])) return true;
    return false;
  }

  Future<void> _pickPrimary() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return;
    if (_isDangerousPath(path)) {
      _showVolumeRootError();
      return;
    }
    setState(() {
      _primaryPath = path;
    });
  }

  Future<void> _addSecondary() async {
    if (_secondaryPaths.length >= 2) return;
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return;
    if (_isDangerousPath(path)) {
      _showVolumeRootError();
      return;
    }
    if (path == _primaryPath || _secondaryPaths.contains(path)) return;
    setState(() {
      _secondaryPaths.add(path);
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

  void _removeSecondary(int index) {
    setState(() {
      _secondaryPaths.removeAt(index);
    });
  }

  bool get _canScan =>
      _primaryPath != null && _secondaryPaths.isNotEmpty;

  // ---------------------------------------------------------------------------
  // Scan
  // ---------------------------------------------------------------------------

  Future<void> _startScan() async {
    final sources = [_primaryPath!, ..._secondaryPaths];
    final initialStates = <String, _SourceScanState>{
      _primaryPath!: _SourceScanState(status: _SourceScanStatus.scanning),
      for (final s in _secondaryPaths)
        s: _SourceScanState(status: _SourceScanStatus.waiting),
    };
    setState(() {
      _phase = _Phase.scanning;
      _scanProgressSource = _primaryPath!;
      _scanSources = sources;
      _scanStates = initialStates;
      _errorMessage = null;
      _diffs = [];
      _sessionId = null;
    });

    String? sessionId;
    List<SecondaryDiff> diffs = [];

    await for (final event in _service.scan(
      primary: _primaryPath!,
      secondaries: _secondaryPaths,
    )) {
      switch (event) {
        case ConsolidateProgress(:final source, :final filesScanned):
          setState(() {
            // If source changed, mark the previous source as done.
            if (source != _scanProgressSource) {
              _scanStates[_scanProgressSource]?.status =
                  _SourceScanStatus.done;
              _scanStates[source]?.status = _SourceScanStatus.scanning;
            }
            _scanProgressSource = source;
            _scanStates[source]?.filesScanned = filesScanned;
          });
        case ConsolidateScanComplete(
            sessionId: final sid,
            secondaries: final secs,
          ):
          sessionId = sid;
          diffs = secs;
        case ConsolidateError(:final message):
          setState(() {
            _errorMessage = message;
            _phase = _Phase.sourceSelection;
          });
          return;
        default:
          break;
      }
    }

    if (sessionId == null) {
      setState(() {
        _errorMessage = 'Scan did not complete — no result received.';
        _phase = _Phase.sourceSelection;
      });
      return;
    }

    // Build review items — all Keep by default.
    final items = <_ReviewItem>[];
    for (final diff in diffs) {
      for (final file in diff.uniqueFiles) {
        items.add(_ReviewItem(secondaryPath: diff.path, file: file));
      }
    }

    for (final s in _scanStates.values) {
      s.status = _SourceScanStatus.done;
    }
    setState(() {
      _sessionId = sessionId;
      _diffs = diffs;
      _reviewItems = items;
      _phase = _Phase.review;
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  Future<void> _startBuild() async {
    final sessionId = _sessionId!;

    // Derive target path: <primary>_consolidated
    final primary = _primaryPath!;
    final target = '${primary}_consolidated';

    final kept = _reviewItems.where((item) => item.keep).toList();

    final foldIns = kept
        .map((item) => FoldInCmd(
              sourceRoot: item.secondaryPath,
              relativePath: item.file.relativePath,
            ))
        .toList();

    setState(() {
      _phase = _Phase.building;
      _buildFilesTotal = kept.length;
      _buildFilesDone = 0;
      _targetPath = target;
      _errorMessage = null;
    });

    int filesCopied = 0;

    await for (final event in _service.build(
      sessionId: sessionId,
      target: target,
      foldIns: foldIns,
    )) {
      switch (event) {
        case ConsolidateProgress(:final filesScanned):
          setState(() {
            _buildFilesDone = filesScanned;
          });
        case ConsolidateBuildComplete(filesCopied: final n):
          filesCopied = n;
        case ConsolidateError(:final message):
          setState(() {
            _errorMessage = message;
            _phase = _Phase.review;
          });
          return;
        default:
          break;
      }
    }

    setState(() {
      _filesCopied = filesCopied;
      _phase = _Phase.result;
    });
  }

  // ---------------------------------------------------------------------------
  // Finalize
  // ---------------------------------------------------------------------------

  Future<void> _finalize() async {
    final sessionId = _sessionId!;

    await for (final event in _service.finalize(sessionId: sessionId)) {
      if (event is ConsolidateError) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(event.message)),
          );
        }
        return;
      }
    }

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  // ---------------------------------------------------------------------------
  // Formatting
  // ---------------------------------------------------------------------------

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _shortPath(String path) {
    final parts = path.split('/');
    return parts.length > 3
        ? '…/${parts.sublist(parts.length - 2).join('/')}'
        : path;
  }

  String _leafName(String path) => path.split('/').last;

  // ---------------------------------------------------------------------------
  // Build: phase views
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Consolidate'),
        leading: _phase == _Phase.scanning || _phase == _Phase.building
            ? const SizedBox.shrink()
            : null,
      ),
      body: switch (_phase) {
        _Phase.sourceSelection => _buildSourceSelection(),
        _Phase.scanning => _buildScanning(),
        _Phase.review => _buildReview(),
        _Phase.building => _buildBuilding(),
        _Phase.result => _buildResult(),
      },
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
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_errorMessage != null)
                  _ErrorBanner(message: _errorMessage!),
                _SectionHeader(
                  title: 'Primary Source',
                  subtitle: 'The base directory. Its content defines what is already present.',
                ),
                const SizedBox(height: 8),
                if (_primaryPath != null)
                  _SourceTile(
                    path: _primaryPath!,
                    label: 'Primary',
                    color: Colors.blue[700]!,
                    onRemove: () => setState(() => _primaryPath = null),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: _pickPrimary,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Choose Primary Folder…'),
                  ),
                const SizedBox(height: 24),
                _SectionHeader(
                  title: 'Secondary Sources',
                  subtitle: 'Up to 2 additional directories. Unique content will be folded into the output.',
                ),
                const SizedBox(height: 8),
                ..._secondaryPaths.asMap().entries.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _SourceTile(
                        path: e.value,
                        label: 'Secondary ${e.key + 1}',
                        color: Colors.teal[700]!,
                        onRemove: () => _removeSecondary(e.key),
                      ),
                    )),
                if (_secondaryPaths.length < 2)
                  OutlinedButton.icon(
                    onPressed: _addSecondary,
                    icon: const Icon(Icons.add),
                    label: const Text('Add Secondary Folder…'),
                  ),
              ],
            ),
          ),
        ),
        _BottomBar(
          child: ElevatedButton.icon(
            onPressed: _canScan ? _startScan : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0E70C0),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.search),
            label: const Text('Scan Sources'),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Phase: scanning
  // ---------------------------------------------------------------------------

  Widget _buildScanning() {
    final doneCount =
        _scanStates.values.where((s) => s.status == _SourceScanStatus.done).length;
    final total = _scanSources.length;
    final overallProgress = total > 0 ? doneCount / total : null;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Scanning sources…',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            LinearProgressIndicator(value: overallProgress),
            const SizedBox(height: 24),
            for (int i = 0; i < _scanSources.length; i++) ...[
              _ScanSourceRow(
                label: i == 0 ? 'Primary' : 'Secondary $i',
                name: _leafName(_scanSources[i]),
                state: _scanStates[_scanSources[i]] ??
                    _SourceScanState(status: _SourceScanStatus.waiting),
              ),
              if (i < _scanSources.length - 1) const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Phase: review
  // ---------------------------------------------------------------------------

  Widget _buildReview() {
    final keepCount = _reviewItems.where((i) => i.keep).length;
    final skipCount = _reviewItems.length - keepCount;
    final totalBytes = _reviewItems
        .where((i) => i.keep)
        .fold<int>(0, (s, i) => s + i.file.sizeBytes);

    if (_reviewItems.isEmpty) {
      return Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 64, color: Colors.green[600]),
                    const SizedBox(height: 16),
                    const Text(
                      'No unique files found',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'All files in the secondary sources are already present in the primary.',
                      style: TextStyle(
                          fontSize: 14, color: Colors.grey[600]),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
          _BottomBar(
            child: TextButton(
              onPressed: () => setState(() => _phase = _Phase.sourceSelection),
              child: const Text('Back to Source Selection'),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
            children: [
              for (final diff in _diffs) ...[
                _SecondaryHeader(
                  path: diff.path,
                  uniqueCount: diff.uniqueFiles.length,
                ),
                for (final item in _reviewItems
                    .where((i) => i.secondaryPath == diff.path)) ...[
                  _ReviewRow(
                    item: item,
                    formatSize: _formatSize,
                    onToggle: (keep) => setState(() => item.keep = keep),
                  ),
                ],
              ],
            ],
          ),
        ),
        _ReviewBottomBar(
          keepCount: keepCount,
          skipCount: skipCount,
          totalBytes: totalBytes,
          formatSize: _formatSize,
          onBuild: keepCount > 0 ? _startBuild : null,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Phase: building
  // ---------------------------------------------------------------------------

  Widget _buildBuilding() {
    final progress = _buildFilesTotal > 0
        ? _buildFilesDone / _buildFilesTotal
        : null;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 16),
            const Text(
              'Building output…',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              _buildFilesTotal > 0
                  ? 'Copying $_buildFilesDone / $_buildFilesTotal files'
                  : 'Starting…',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            if (_targetPath != null) ...[
              const SizedBox(height: 4),
              Text(
                '→ ${_shortPath(_targetPath!)}',
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Phase: result
  // ---------------------------------------------------------------------------

  Widget _buildResult() {
    final skipped = _reviewItems.where((i) => !i.keep).toList();

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ResultHeader(
                  filesCopied: _filesCopied,
                  targetPath: _targetPath,
                  shortPath: _shortPath,
                ),
                const SizedBox(height: 24),
                for (final diff in _diffs)
                  _ResultSecondaryCard(
                    diff: diff,
                    reviewItems: _reviewItems,
                    shortPath: _shortPath,
                    leafName: _leafName,
                    formatSize: _formatSize,
                  ),
                if (skipped.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _SkippedSection(
                    skipped: skipped,
                    leafName: _leafName,
                    formatSize: _formatSize,
                  ),
                ],
              ],
            ),
          ),
        ),
        _BottomBar(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton.icon(
                onPressed: _finalize,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[700],
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.check),
                label: const Text('Finalize — Mark Session Complete'),
              ),
              const SizedBox(height: 8),
              Text(
                'Finalizing records this session in the registry so you can '
                'safely verify before deleting source directories.',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Small reusable widgets
// ---------------------------------------------------------------------------

class _ScanSourceRow extends StatelessWidget {
  final String label;
  final String name;
  final _SourceScanState state;

  const _ScanSourceRow({
    required this.label,
    required this.name,
    required this.state,
  });

  @override
  Widget build(BuildContext context) {
    final isDone = state.status == _SourceScanStatus.done;
    final isScanning = state.status == _SourceScanStatus.scanning;
    final isWaiting = state.status == _SourceScanStatus.waiting;

    final statusIcon = isDone
        ? Icon(Icons.check_circle, size: 16, color: Colors.green[700])
        : isScanning
            ? SizedBox(
                width: 16,
                height: 16,
                child: LinearProgressIndicator(
                  borderRadius: BorderRadius.circular(2),
                ),
              )
            : Icon(Icons.radio_button_unchecked,
                size: 16, color: Colors.grey[400]);

    final fileLabel = isDone
        ? (state.filesScanned > 0 ? '${state.filesScanned} files' : 'done')
        : isScanning
            ? state.filesScanned > 0
                ? '${state.filesScanned} files…'
                : 'hashing…'
            : 'waiting';

    return Row(
      children: [
        statusIcon,
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$label: $name',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isWaiting ? Colors.grey[400] : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                fileLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: isDone
                      ? Colors.green[700]
                      : isScanning
                          ? Colors.blue[700]
                          : Colors.grey[400],
                ),
              ),
            ],
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
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
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

class _SecondaryHeader extends StatelessWidget {
  final String path;
  final int uniqueCount;

  const _SecondaryHeader({required this.path, required this.uniqueCount});

  String get _leafName => path.split('/').last;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Icon(Icons.folder, size: 16, color: Colors.teal[700]),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _leafName,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.teal[700],
                fontSize: 14,
              ),
            ),
          ),
          Text(
            '$uniqueCount unique',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}

class _ReviewRow extends StatelessWidget {
  final _ReviewItem item;
  final String Function(int) formatSize;
  final void Function(bool) onToggle;

  const _ReviewRow({
    required this.item,
    required this.formatSize,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(
        Icons.insert_drive_file,
        size: 18,
        color: item.keep ? Colors.blue[700] : Colors.grey[400],
      ),
      title: Text(
        item.file.relativePath,
        style: TextStyle(
          fontSize: 13,
          color: item.keep ? null : Colors.grey[400],
          decoration: item.keep ? null : TextDecoration.lineThrough,
        ),
      ),
      subtitle: Text(
        formatSize(item.file.sizeBytes),
        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
      ),
      trailing: Switch(
        value: item.keep,
        onChanged: onToggle,
      ),
    );
  }
}

class _ReviewBottomBar extends StatelessWidget {
  final int keepCount;
  final int skipCount;
  final int totalBytes;
  final String Function(int) formatSize;
  final VoidCallback? onBuild;

  const _ReviewBottomBar({
    required this.keepCount,
    required this.skipCount,
    required this.totalBytes,
    required this.formatSize,
    required this.onBuild,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: Colors.grey[200]!)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$keepCount to fold in  •  ${formatSize(totalBytes)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13),
              ),
              if (skipCount > 0)
                Text(
                  '$skipCount skipped',
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onBuild,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0E70C0),
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.content_copy),
              label: const Text('Build Output Directory'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultHeader extends StatelessWidget {
  final int filesCopied;
  final String? targetPath;
  final String Function(String) shortPath;

  const _ResultHeader({
    required this.filesCopied,
    required this.targetPath,
    required this.shortPath,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.green[50],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.green[200]!),
      ),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green[700], size: 20),
                const SizedBox(width: 8),
                Text(
                  'Build complete',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.green[800],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '$filesCopied file${filesCopied == 1 ? '' : 's'} copied',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.green[700]),
            ),
            if (targetPath != null) ...[
              const SizedBox(height: 4),
              Text(
                '→ ${shortPath(targetPath!)}',
                style: TextStyle(fontSize: 12, color: Colors.green[800]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResultSecondaryCard extends StatelessWidget {
  final SecondaryDiff diff;
  final List<_ReviewItem> reviewItems;
  final String Function(String) shortPath;
  final String Function(String) leafName;
  final String Function(int) formatSize;

  const _ResultSecondaryCard({
    required this.diff,
    required this.reviewItems,
    required this.shortPath,
    required this.leafName,
    required this.formatSize,
  });

  @override
  Widget build(BuildContext context) {
    final items =
        reviewItems.where((i) => i.secondaryPath == diff.path).toList();
    final kept = items.where((i) => i.keep).length;
    final skipped = items.where((i) => !i.keep).length;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.folder, size: 16, color: Colors.teal[700]),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    leafName(diff.path),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 16,
              children: [
                Text('$kept folded in',
                    style: TextStyle(
                        fontSize: 13, color: Colors.green[700])),
                if (skipped > 0)
                  Text('$skipped skipped',
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey[600])),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SkippedSection extends StatefulWidget {
  final List<_ReviewItem> skipped;
  final String Function(String) leafName;
  final String Function(int) formatSize;

  const _SkippedSection({
    required this.skipped,
    required this.leafName,
    required this.formatSize,
  });

  @override
  State<_SkippedSection> createState() => _SkippedSectionState();
}

class _SkippedSectionState extends State<_SkippedSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: Colors.grey[500],
                ),
                const SizedBox(width: 4),
                Text(
                  '${widget.skipped.length} file${widget.skipped.length == 1 ? '' : 's'} skipped (recorded in session registry)',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          for (final item in widget.skipped)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 0, 2),
              child: Text(
                '${widget.leafName(item.secondaryPath)} / ${item.file.relativePath}  •  ${widget.formatSize(item.file.sizeBytes)}',
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
            ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import 'consolidate_models.dart';
import 'consolidate_service.dart';

// ---------------------------------------------------------------------------
// ConsolidateScan2Screen
//
// Phase 2 — Content scan: shows scan progress, then the deduplication plan.
// Surfaces:
//   • Summary stats (files to copy, duplicates skipped, total size)
//   • Filename collisions (auto-renamed with sequential suffix — user can
//     override the suggested name)
//   • Ambiguities (unclear placement flagged for user awareness)
// ---------------------------------------------------------------------------

class ConsolidateScan2Screen extends StatefulWidget {
  const ConsolidateScan2Screen({
    super.key,
    required this.sourceFolders,
    required this.excludedExtensions,
    required this.excludedFolders,
    this.overriddenPaths = const [],
    required this.service,
    required this.onProceed,
    required this.onBack,
  });

  final List<String> sourceFolders;
  final List<String> excludedExtensions;
  final List<String> excludedFolders;
  final List<String> overriddenPaths;
  final ConsolidateService service;

  /// Called with the final routing plan and any user collision overrides.
  /// [collisionOverrides] maps '${sourceFolder}|${sourceRelativePath}' →
  /// full override target relative path (e.g. 'photos/my_rename.jpg').
  final void Function(
    ContentScanComplete result,
    Map<String, String> collisionOverrides,
  ) onProceed;
  final VoidCallback onBack;

  @override
  State<ConsolidateScan2Screen> createState() =>
      _ConsolidateScan2ScreenState();
}

class _ConsolidateScan2ScreenState extends State<ConsolidateScan2Screen> {
  bool _scanning = true;
  int _filesHashed = 0;
  int _totalFiles = 0;
  String _scanStatus = 'Hashing files…';

  ContentScanComplete? _result;
  String? _error;

  // Collision override: targetRelativePath → user-entered name override.
  final Map<String, String> _collisionOverrides = {};
  final Map<String, TextEditingController> _collisionControllers = {};

  @override
  void initState() {
    super.initState();
    _runScan();
  }

  @override
  void dispose() {
    for (final c in _collisionControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

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
          setState(() {
            _filesHashed = event.filesScanned;
            _scanStatus = 'Hashed $_filesHashed files…';
          });
        } else if (event is ContentScanComplete) {
          // Pre-populate collision controllers with suggested renames.
          for (final col in event.collisions) {
            for (final entry in col.entries) {
              final key =
                  '${entry.sourceFolder}|${entry.sourceRelativePath}';
              _collisionControllers[key] =
                  TextEditingController(text: entry.renamedTo);
            }
          }
          setState(() {
            _scanning = false;
            _result = event;
            _totalFiles = event.filesToCopy + event.duplicatesSkipped;
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

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  String _shortPath(String path) => path.split('/').last;

  void _proceed() {
    if (_result == null) return;
    // Collect final override values from all controllers.
    final Map<String, String> overrides = {};
    _collisionControllers.forEach((key, ctrl) {
      overrides[key] = ctrl.text;
    });
    widget.onProceed(_result!, overrides);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(),
        if (_scanning) _buildProgress(),
        if (_error != null) _buildError(),
        if (_result != null && !_scanning) ...[
          Expanded(child: _buildResults(_result!)),
          _buildBottomBar(_result!),
        ],
      ],
    );
  }

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
                tooltip: 'Back to Step 1',
              ),
              const SizedBox(width: 8),
              const Text(
                'Step 2: Consolidation Plan',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const Divider(height: 24),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    final progress = _totalFiles > 0 ? _filesHashed / _totalFiles : null;
    return Expanded(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 16),
              Text(_scanStatus,
                  style: const TextStyle(fontSize: 14)),
              if (_filesHashed > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '$_filesHashed files hashed',
                  style: const TextStyle(
                      fontSize: 12, color: Colors.black45),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Expanded(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(_error!,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults(ContentScanComplete result) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSummaryCard(result),
          const SizedBox(height: 20),

          // Collisions section.
          if (result.collisions.isNotEmpty) ...[
            _buildSectionHeader(
              'Filename Collisions (${result.collisions.length})',
              subtitle:
                  'These files would share a name in the output. '
                  'Each has been renamed automatically — edit if needed.',
              color: Colors.orange.shade700,
            ),
            const SizedBox(height: 8),
            ...result.collisions.map((c) => _buildCollisionCard(c)),
            const SizedBox(height: 20),
          ],

          // Ambiguities section.
          if (result.ambiguities.isNotEmpty) ...[
            _buildSectionHeader(
              'Ambiguities (${result.ambiguities.length})',
              subtitle:
                  'These cases were noted during analysis. '
                  'Review before building.',
              color: Colors.amber.shade800,
            ),
            const SizedBox(height: 8),
            ...result.ambiguities.map((a) => _buildAmbiguityCard(a)),
            const SizedBox(height: 20),
          ],

          // Duplicate summary.
          if (result.duplicatesSkipped > 0) ...[
            _buildSectionHeader(
              'Duplicates Removed (${result.duplicatesSkipped})',
              subtitle:
                  'These files have identical content to another copy. '
                  'Only the best-organised copy will be kept.',
            ),
            const SizedBox(height: 8),
            _buildDuplicateSummaryCard(result),
          ],
        ],
      ),
    );
  }

  Widget _buildSummaryCard(ContentScanComplete result) {
    return Card(
      elevation: 0,
      color: Colors.green.shade50,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildStat(
                'Files to Copy', '${result.filesToCopy}', Colors.green.shade700),
            _buildStat(
                'Duplicates Removed',
                '${result.duplicatesSkipped}',
                Colors.orange.shade700),
            _buildStat(
                'Output Size',
                _formatBytes(result.totalOutputSizeBytes),
                Colors.blue.shade700),
            _buildStat(
                'Collisions',
                '${result.collisions.length}',
                result.collisions.isEmpty
                    ? Colors.green.shade700
                    : Colors.orange.shade700),
          ],
        ),
      ),
    );
  }

  Widget _buildStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(fontSize: 12, color: Colors.black54)),
      ],
    );
  }

  Widget _buildSectionHeader(String title,
      {String? subtitle, Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: color)),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(subtitle,
              style: const TextStyle(
                  fontSize: 12, color: Colors.black54)),
        ],
      ],
    );
  }

  Widget _buildCollisionCard(FilenameCollision collision) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.orange.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Original target that had the conflict.
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 16, color: Colors.orange),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    collision.targetRelativePath,
                    style: const TextStyle(
                        fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Each colliding file with rename field.
            ...collision.entries.map((entry) {
              final key =
                  '${entry.sourceFolder}|${entry.sourceRelativePath}';
              final ctrl = _collisionControllers[key];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Icon(Icons.subdirectory_arrow_right,
                        size: 14, color: Colors.black38),
                    const SizedBox(width: 6),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _shortPath(entry.sourceFolder),
                            style: const TextStyle(
                                fontSize: 11, color: Colors.black45),
                          ),
                          Text(
                            entry.sourceRelativePath,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.arrow_forward,
                        size: 14, color: Colors.black38),
                    const SizedBox(width: 8),
                    // Editable rename target.
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
                                hintText: 'renamed_file.ext',
                              ),
                              onChanged: (val) {
                                _collisionOverrides[key] = val;
                              },
                            )
                          : Text(entry.renamedTo,
                              style: const TextStyle(fontSize: 12)),
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

  Widget _buildAmbiguityCard(ContentScanAmbiguity ambiguity) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.amber.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: Colors.amber.shade800),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    ambiguity.description,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            if (ambiguity.files.isNotEmpty) ...[
              const SizedBox(height: 8),
              // Show first 5 files.
              ...ambiguity.files.take(5).map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(left: 22, bottom: 2),
                      child: Text(
                        f,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.black54),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              if (ambiguity.files.length > 5)
                Padding(
                  padding: const EdgeInsets.only(left: 22),
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
    );
  }

  Widget _buildDuplicateSummaryCard(ContentScanComplete result) {
    // Show a sample of duplicate groups (files with skip_duplicate action).
    final dupeFiles = result.routing
        .where((r) => r.action == 'skip_duplicate')
        .take(5)
        .toList();

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...dupeFiles.map((rf) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.remove_circle_outline,
                          size: 14, color: Colors.orange),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          rf.sourceRelativePath,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.black54),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'dup of ${rf.duplicateOf?.split('/').last ?? ''}',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.black38),
                      ),
                    ],
                  ),
                )),
            if (result.duplicatesSkipped > 5) ...[
              const SizedBox(height: 4),
              Text(
                '… and ${result.duplicatesSkipped - 5} more duplicates',
                style: const TextStyle(
                    fontSize: 12, color: Colors.black45),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(ContentScanComplete result) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${result.filesToCopy} files to copy, '
              '${result.duplicatesSkipped} duplicates removed, '
              '${_formatBytes(result.totalOutputSizeBytes)} output',
              style:
                  const TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _proceed,
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: const Text('Review & Build'),
          ),
        ],
      ),
    );
  }
}

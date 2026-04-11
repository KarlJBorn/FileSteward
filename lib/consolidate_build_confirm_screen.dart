import 'package:flutter/material.dart';

import 'consolidate_models.dart';
import 'consolidate_service.dart';

// ---------------------------------------------------------------------------
// ConsolidateBuildConfirmScreen
//
// Phase 3 — Build Confirmation and Execution.
//
// States:
//   preview   → Show plan summary + target tree overview; Back / Start Build
//   building  → Progress bar, live log, abort not available (non-destructive)
//   complete  → Summary stats, open-folder shortcut, Done button
// ---------------------------------------------------------------------------

enum _BuildPhase { preview, building, complete }

class ConsolidateBuildConfirmScreen extends StatefulWidget {
  const ConsolidateBuildConfirmScreen({
    super.key,
    required this.result,
    required this.collisionOverrides,
    required this.sourceFolders,
    required this.targetPath,
    required this.service,
    required this.onComplete,
    required this.onBack,
  });

  final ContentScanComplete result;

  /// Maps '${sourceFolder}|${sourceRelativePath}' → user-chosen target
  /// relative path (filename may differ from auto-generated rename).
  final Map<String, String> collisionOverrides;

  final List<String> sourceFolders;
  final String targetPath;
  final ConsolidateService service;

  /// Called when the build finishes successfully.
  final void Function(int filesCopied, String targetPath) onComplete;
  final VoidCallback onBack;

  @override
  State<ConsolidateBuildConfirmScreen> createState() =>
      _ConsolidateBuildConfirmScreenState();
}

class _ConsolidateBuildConfirmScreenState
    extends State<ConsolidateBuildConfirmScreen> {
  _BuildPhase _phase = _BuildPhase.preview;

  int _filesCopied = 0;
  int _filesTotal = 0;
  String? _error;

  // Log entries: (isError, message)
  final List<(bool, String)> _log = [];

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

  String _shortPath(String path) => path.split('/').last;

  /// Build the final routing list, applying user collision overrides.
  List<V3RoutedFileCmd> _buildRouting() {
    final List<V3RoutedFileCmd> out = [];
    for (final rf in widget.result.routing) {
      if (rf.action == 'skip_duplicate') continue;
      final key = '${rf.sourceFolder}|${rf.sourceRelativePath}';
      final overrideTarget = widget.collisionOverrides[key];
      final targetRelPath = (overrideTarget != null && overrideTarget.isNotEmpty)
          ? overrideTarget
          : rf.targetRelativePath;
      out.add(V3RoutedFileCmd(
        sourceFolder: rf.sourceFolder,
        sourceRelativePath: rf.sourceRelativePath,
        targetRelativePath: targetRelPath,
      ));
    }
    return out;
  }

  /// Group routing by top-level output folder for the preview tree.
  /// Returns a sorted list of (folderName, fileCount, sizeBytes).
  List<(String, int, int)> _buildFolderSummary() {
    final Map<String, (int, int)> groups = {};
    for (final rf in widget.result.routing) {
      if (rf.action == 'skip_duplicate') continue;
      final key = '${rf.sourceFolder}|${rf.sourceRelativePath}';
      final overrideTarget = widget.collisionOverrides[key];
      final targetRelPath = (overrideTarget != null && overrideTarget.isNotEmpty)
          ? overrideTarget
          : rf.targetRelativePath;
      final parts = targetRelPath.split('/');
      final topFolder = parts.length > 1 ? parts.first : '(root)';
      final prev = groups[topFolder] ?? (0, 0);
      groups[topFolder] = (prev.$1 + 1, prev.$2 + rf.sizeBytes);
    }
    final list = groups.entries
        .map((e) => (e.key, e.value.$1, e.value.$2))
        .toList();
    list.sort((a, b) => a.$1.compareTo(b.$1));
    return list;
  }

  // ---------------------------------------------------------------------------
  // Build execution
  // ---------------------------------------------------------------------------

  void _startBuild() {
    final routing = _buildRouting();
    setState(() {
      _phase = _BuildPhase.building;
      _filesTotal = routing.length;
      _filesCopied = 0;
      _log.clear();
      _log.add((false, 'Starting build → ${widget.targetPath}'));
    });

    widget.service
        .v3Build(target: widget.targetPath, routing: routing)
        .listen(
      (event) {
        if (!mounted) return;
        if (event is ConsolidateProgress) {
          setState(() {
            _filesCopied = event.filesScanned;
          });
        } else if (event is ConsolidateBuildComplete) {
          setState(() {
            _filesCopied = event.filesCopied;
            _phase = _BuildPhase.complete;
            _log.add((false, 'Done — ${event.filesCopied} files copied.'));
          });
          widget.onComplete(event.filesCopied, widget.targetPath);
        } else if (event is ConsolidateError) {
          setState(() {
            _error = event.message;
            _phase = _BuildPhase.preview; // let user try again / go back
            _log.add((true, event.message));
          });
        }
      },
      onError: (e) {
        if (!mounted) return;
        setState(() {
          _error = e.toString();
          _phase = _BuildPhase.preview;
          _log.add((true, e.toString()));
        });
      },
    );
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
        if (_phase == _BuildPhase.preview) ...[
          Expanded(child: _buildPreview()),
          _buildPreviewBottomBar(),
        ],
        if (_phase == _BuildPhase.building) ...[
          Expanded(child: _buildBuildingView()),
        ],
        if (_phase == _BuildPhase.complete) ...[
          Expanded(child: _buildCompleteView()),
          _buildCompleteBottomBar(),
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
              if (_phase == _BuildPhase.preview)
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onBack,
                  tooltip: 'Back to Step 2',
                )
              else
                const SizedBox(width: 8),
              const SizedBox(width: 8),
              Text(
                _phase == _BuildPhase.preview
                    ? 'Step 3: Review & Build'
                    : _phase == _BuildPhase.building
                        ? 'Building…'
                        : 'Build Complete',
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
  // Preview
  // ---------------------------------------------------------------------------

  Widget _buildPreview() {
    final result = widget.result;
    final folderSummary = _buildFolderSummary();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Summary card.
          _buildSummaryCard(result),
          const SizedBox(height: 20),

          // Target path.
          _buildSectionHeader('Output Location'),
          const SizedBox(height: 8),
          _buildTargetCard(),
          const SizedBox(height: 20),

          // Output folder tree.
          _buildSectionHeader(
            'Output Structure',
            subtitle: 'Files will be organised into these top-level folders.',
          ),
          const SizedBox(height: 8),
          _buildFolderTree(folderSummary),

          // Collision summary.
          if (result.collisions.isNotEmpty) ...[
            const SizedBox(height: 20),
            _buildSectionHeader(
              'Renamed Files (${result.collisions.length} collisions resolved)',
              subtitle: 'Files that were renamed to avoid conflicts.',
              color: Colors.orange.shade700,
            ),
            const SizedBox(height: 8),
            _buildCollisionSummary(result.collisions),
          ],

          // Error banner if last build attempt failed.
          if (_error != null) ...[
            const SizedBox(height: 16),
            _buildErrorBanner(),
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
            _buildStat('Files to Copy', '${result.filesToCopy}',
                Colors.green.shade700),
            _buildStat('Duplicates Removed', '${result.duplicatesSkipped}',
                Colors.orange.shade700),
            _buildStat('Output Size',
                _formatBytes(result.totalOutputSizeBytes), Colors.blue.shade700),
            _buildStat(
                'Sources', '${widget.sourceFolders.length}', Colors.grey.shade700),
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

  Widget _buildTargetCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.blue.shade100),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.folder_outlined, color: Colors.blue.shade700, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _shortPath(widget.targetPath),
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  Text(
                    widget.targetPath,
                    style: const TextStyle(
                        fontSize: 11, color: Colors.black45),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderTree(List<(String, int, int)> folders) {
    if (folders.isEmpty) {
      return Text(
        'No files to copy.',
        style: TextStyle(fontSize: 13, color: Colors.black54),
      );
    }
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: folders.map((entry) {
            final (folder, count, size) = entry;
            return ListTile(
              dense: true,
              leading: Icon(Icons.folder, color: Colors.blue.shade400, size: 18),
              title: Text(
                folder,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
              trailing: Text(
                '$count files · ${_formatBytes(size)}',
                style: const TextStyle(fontSize: 12, color: Colors.black45),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildCollisionSummary(List<FilenameCollision> collisions) {
    final shown = collisions.take(5).toList();
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.orange.shade100),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...shown.map((col) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    const Icon(Icons.drive_file_rename_outline,
                        size: 14, color: Colors.orange),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        col.targetRelativePath,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.black54),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${col.entries.length} rename(s)',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.black38),
                    ),
                  ],
                ),
              );
            }),
            if (collisions.length > 5) ...[
              const SizedBox(height: 4),
              Text(
                '… and ${collisions.length - 5} more',
                style: const TextStyle(fontSize: 12, color: Colors.black45),
              ),
            ],
          ],
        ),
      ),
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
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
      ],
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewBottomBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${widget.result.filesToCopy} files → ${_shortPath(widget.targetPath)}',
              style:
                  const TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _startBuild,
            icon: const Icon(Icons.content_copy, size: 18),
            label: const Text('Start Build'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Building
  // ---------------------------------------------------------------------------

  Widget _buildBuildingView() {
    final progress = _filesTotal > 0 ? _filesCopied / _filesTotal : 0.0;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Progress bar.
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 12),
          Text(
            'Copying $_filesCopied of $_filesTotal files…',
            style: const TextStyle(fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            '→ ${widget.targetPath}',
            style: const TextStyle(fontSize: 12, color: Colors.black45),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 24),

          // Live log.
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: ListView.builder(
                padding: const EdgeInsets.all(10),
                itemCount: _log.length,
                itemBuilder: (context, i) {
                  final (isError, msg) = _log[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      msg,
                      style: TextStyle(
                        fontSize: 11,
                        color: isError ? Colors.red : Colors.black54,
                        fontFamily: 'monospace',
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Complete
  // ---------------------------------------------------------------------------

  Widget _buildCompleteView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 64, color: Colors.green.shade600),
            const SizedBox(height: 16),
            Text(
              'Build Complete',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.green.shade700),
            ),
            const SizedBox(height: 8),
            Text(
              '$_filesCopied files copied',
              style: const TextStyle(fontSize: 16, color: Colors.black54),
            ),
            const SizedBox(height: 4),
            Text(
              widget.targetPath,
              style: const TextStyle(fontSize: 12, color: Colors.black38),
              textAlign: TextAlign.center,
            ),
            if (widget.result.duplicatesSkipped > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${widget.result.duplicatesSkipped} duplicates removed',
                  style: TextStyle(
                      fontSize: 13, color: Colors.orange.shade700),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCompleteBottomBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${_formatBytes(widget.result.totalOutputSizeBytes)} written to ${_shortPath(widget.targetPath)}',
              style:
                  const TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: () =>
                widget.onComplete(_filesCopied, widget.targetPath),
            icon: const Icon(Icons.done, size: 18),
            label: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'agent_board_status_writer.dart';
import 'manifest_filter.dart';
import 'manifest_models.dart';
import 'manifest_service.dart';

void main() {
  runApp(const FileStewardApp());
}

class FileStewardApp extends StatelessWidget {
  const FileStewardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FileSteward',
      debugShowCheckedModeBanner: false,
      home: const FileStewardHomePage(),
    );
  }
}

class FileStewardHomePage extends StatefulWidget {
  const FileStewardHomePage({super.key});

  @override
  State<FileStewardHomePage> createState() => _FileStewardHomePageState();
}

class _FileStewardHomePageState extends State<FileStewardHomePage> {
  final ManifestService _manifestService = const ManifestService();
  final AgentBoardStatusWriter _statusWriter = const AgentBoardStatusWriter();
  String? _selectedFolderPath;
  String _statusMessage = 'Choose a folder, then build a recursive manifest.';
  // Inventory (fast pass — runs automatically after folder selection)
  InventoryResult? _inventoryResult;
  bool _isInventoryRunning = false;
  bool _sourcesExpanded = false;
  Set<String> _selectedExtensions = {};

  // Full manifest (hashing pass)
  ManifestResult? _manifestResult;
  bool _isRunning = false;
  ManifestEntryFilter _entryFilter = ManifestEntryFilter.all;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _commandPoller;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_handleSearchChanged);
    _commandPoller = Timer.periodic(const Duration(seconds: 2), (_) {
      _checkForCommands();
    });
    _writeDashboardStatus(
      status: 'waiting',
      progressLabel: 'Choose a folder to begin.',
      taskTitle: 'Await folder selection',
      taskSummary: 'FileSteward is idle and waiting for a folder to inspect.',
      checkpoint: 'Choose Folder',
    );
  }

  @override
  void dispose() {
    _commandPoller?.cancel();
    _searchController
      ..removeListener(_handleSearchChanged)
      ..dispose();
    super.dispose();
  }

  void _handleSearchChanged() {
    final nextQuery = _searchController.text;
    if (nextQuery == _searchQuery) {
      return;
    }

    setState(() {
      _searchQuery = nextQuery;
    });
  }

  Future<void> _checkForCommands() async {
    final commands = await _statusWriter.readPendingCommands(
      agentId: 'filesteward',
    );
    for (final command in commands) {
      await _handleCommand(command);
    }
  }

  Future<void> _handleCommand(AgentBoardCommand command) async {
    switch (command.command) {
      case 'approve':
        setState(() {
          _statusMessage = 'Approval received from AgentBoard.';
        });
        await _writeDashboardStatus(
          status: 'waiting',
          progressLabel: _selectedFolderPath == null
              ? 'Approval received. Choose a folder to continue.'
              : 'Approval received. Ready to continue.',
          taskTitle: 'Approval received',
          taskSummary: _selectedFolderPath == null
              ? 'AgentBoard approved the workflow. Choose a folder to continue.'
              : 'AgentBoard approved the workflow. Ready for the next manifest action.',
          checkpoint: _selectedFolderPath == null
              ? 'Choose Folder'
              : 'Build Manifest',
          eventType: 'approval',
          eventMessage: 'Received approval from AgentBoard.',
        );
        await _statusWriter.appendReceipt(
          commandId: command.id,
          outcome: 'processed',
          message: 'Approval acknowledged.',
        );
        break;
      case 'retry':
        await _statusWriter.appendReceipt(
          commandId: command.id,
          outcome: 'processed',
          message: 'Retry requested.',
        );
        if (!_isRunning && _selectedFolderPath != null) {
          unawaited(_buildManifest());
        } else {
          await _writeDashboardStatus(
            status: _selectedFolderPath == null ? 'needs_approval' : 'paused',
            progressLabel:
                'Retry requested but no runnable task is available yet.',
            taskTitle: 'Retry deferred',
            taskSummary: _selectedFolderPath == null
                ? 'Retry requested before a folder was selected.'
                : 'Retry requested while FileSteward is already running.',
            checkpoint: _selectedFolderPath == null
                ? 'Choose Folder'
                : 'Wait for current run',
            eventType: 'note',
            eventMessage: 'Retry requested but no runnable task was available.',
          );
        }
        break;
      case 'request_checkpoint':
        final derivedStatus = _deriveStatus();
        await _writeDashboardStatus(
          status: derivedStatus,
          progressLabel: _deriveProgressLabel(),
          taskTitle: _deriveTaskTitle(),
          taskSummary: _deriveTaskSummary(),
          checkpoint: _deriveCheckpoint(),
          isBlocked: derivedStatus == 'blocked',
          selectedFolderPath: _selectedFolderPath,
          eventType: 'checkpoint',
          eventMessage: 'Checkpoint requested from AgentBoard.',
        );
        await _statusWriter.appendReceipt(
          commandId: command.id,
          outcome: 'processed',
          message: 'Checkpoint emitted.',
        );
        break;
      default:
        await _statusWriter.appendReceipt(
          commandId: command.id,
          outcome: 'ignored',
          message: 'Unknown command ${command.command}.',
        );
    }
  }

  String _deriveStatus() {
    if (_isRunning) {
      return 'working';
    }
    if (_manifestResult != null) {
      return 'completed';
    }
    if (_statusMessage.startsWith('Error') ||
        _statusMessage.startsWith('Rust failed')) {
      return 'blocked';
    }
    if (_statusMessage == 'Choose a folder first.') {
      return 'needs_approval';
    }
    return 'waiting';
  }

  String _deriveProgressLabel() {
    if (_isRunning) {
      return 'Building recursive manifest.';
    }
    if (_manifestResult != null) {
      return 'Manifest ready for review.';
    }
    if (_selectedFolderPath != null) {
      return 'Folder selected and ready for manifest build.';
    }
    return 'Choose a folder to begin.';
  }

  String _deriveTaskTitle() {
    if (_isRunning) {
      return 'Build recursive manifest';
    }
    if (_manifestResult != null) {
      return 'Manifest build completed';
    }
    if (_selectedFolderPath != null) {
      return 'Folder selected';
    }
    return 'Await folder selection';
  }

  String _deriveTaskSummary() {
    if (_isRunning) {
      return 'Invoking the Rust manifest builder for $_selectedFolderPath.';
    }
    if (_manifestResult != null) {
      return 'Manifest completed for ${_manifestResult!.selectedFolder}.';
    }
    if (_selectedFolderPath != null) {
      return 'Ready to build a recursive manifest for $_selectedFolderPath.';
    }
    return 'FileSteward is idle and waiting for a folder to inspect.';
  }

  String _deriveCheckpoint() {
    if (_isRunning) {
      return 'Parse Rust JSON output';
    }
    if (_manifestResult != null) {
      return 'Review manifest';
    }
    if (_selectedFolderPath != null) {
      return 'Build Manifest';
    }
    return 'Choose Folder';
  }

  Future<void> _writeDashboardStatus({
    required String status,
    required String progressLabel,
    required String taskTitle,
    required String taskSummary,
    required String checkpoint,
    String? selectedFolderPath,
    String? eventType,
    String? eventMessage,
    bool isBlocked = false,
    List<String> filesTouched = const <String>[],
    List<String> commandsRun = const <String>[],
  }) async {
    try {
      await _statusWriter.writeStatus(
        selectedFolderPath: selectedFolderPath ?? _selectedFolderPath,
        status: status,
        progressLabel: progressLabel,
        taskTitle: taskTitle,
        taskSummary: taskSummary,
        checkpoint: checkpoint,
        isBlocked: isBlocked,
        filesTouched: filesTouched,
        commandsRun: commandsRun,
      );

      if (eventType != null && eventMessage != null) {
        await _statusWriter.appendEvent(
          status: status,
          type: eventType,
          message: eventMessage,
          files: filesTouched,
          commands: commandsRun,
        );
      }
    } catch (_) {
      // Status output should never block the main FileSteward workflow.
    }
  }

  Future<void> _chooseFolder() async {
    try {
      final String? directoryPath = await getDirectoryPath();

      if (directoryPath == null || directoryPath.isEmpty) {
        setState(() {
          _statusMessage = 'Folder selection was canceled.';
        });
        await _writeDashboardStatus(
          status: 'waiting',
          progressLabel: 'Folder selection canceled.',
          taskTitle: 'Await folder selection',
          taskSummary: 'The folder picker was dismissed without a selection.',
          checkpoint: 'Choose Folder',
          eventType: 'note',
          eventMessage: 'Folder selection was canceled.',
        );
        return;
      }

      setState(() {
        _selectedFolderPath = directoryPath;
        _inventoryResult = null;
        _selectedExtensions = {};
        _manifestResult = null;
        _entryFilter = ManifestEntryFilter.all;
        _searchController.clear();
        _statusMessage = 'Scanning file types…';
      });
      unawaited(_runInventory(directoryPath));
      await _writeDashboardStatus(
        status: 'waiting',
        progressLabel: 'Folder selected and ready for manifest build.',
        taskTitle: 'Folder selected',
        taskSummary: 'Ready to build a recursive manifest for $directoryPath.',
        checkpoint: 'Build Manifest',
        eventType: 'selection',
        eventMessage: 'Selected folder: $directoryPath',
      );
    } catch (e) {
      setState(() {
        _manifestResult = null;
        _statusMessage = 'Error choosing folder:\n\n$e';
      });
      await _writeDashboardStatus(
        status: 'blocked',
        progressLabel: 'Folder selection failed.',
        taskTitle: 'Folder selection error',
        taskSummary: 'FileSteward could not complete folder selection.',
        checkpoint: 'Retry Choose Folder',
        eventType: 'error',
        eventMessage: 'Folder selection failed: $e',
        isBlocked: true,
      );
    }
  }

  Future<void> _buildManifest() async {
    if (_selectedFolderPath == null || _selectedFolderPath!.isEmpty) {
      setState(() {
        _manifestResult = null;
        _statusMessage = 'Choose a folder first.';
      });
      await _writeDashboardStatus(
        status: 'needs_approval',
        progressLabel: 'Waiting for a folder to be selected.',
        taskTitle: 'Choose target folder',
        taskSummary:
            'FileSteward needs a folder selection before it can build a manifest.',
        checkpoint: 'Choose Folder',
        eventType: 'note',
        eventMessage: 'Build was requested before a folder was selected.',
      );
      return;
    }

    setState(() {
      _isRunning = true;
      _manifestResult = null;
      _statusMessage = 'Building recursive manifest...';
    });
    await _writeDashboardStatus(
      status: 'working',
      progressLabel: 'Building recursive manifest.',
      taskTitle: 'Build recursive manifest',
      taskSummary:
          'Invoking the Rust manifest builder for $_selectedFolderPath.',
      checkpoint: 'Parse Rust JSON output',
      eventType: 'start',
      eventMessage: 'Started manifest build for $_selectedFolderPath',
      commandsRun: const <String>[
        'cargo build --manifest-path rust_core/Cargo.toml',
        'rust_core/target/debug/rust_core <selected-folder>',
      ],
    );

    try {
      final ManifestResult parsedResult = await _manifestService.buildManifest(
        _selectedFolderPath!,
      );

      setState(() {
        _manifestResult = parsedResult;
        _entryFilter = ManifestEntryFilter.all;
        _searchController.clear();
        _statusMessage = 'Recursive manifest completed.';
      });
      await _writeDashboardStatus(
        status: 'completed',
        progressLabel:
            'Manifest complete: ${parsedResult.totalDirectories} folders, ${parsedResult.totalFiles} files.',
        taskTitle: 'Manifest build completed',
        taskSummary:
            'Completed manifest for ${parsedResult.selectedFolder} with ${parsedResult.entries.length} total entries.',
        checkpoint: 'Review manifest',
        eventType: 'completed',
        eventMessage:
            'Manifest completed for ${parsedResult.selectedFolder} with ${parsedResult.entries.length} entries.',
      );
    } on ManifestServiceException catch (e) {
      setState(() {
        _manifestResult = null;
        _statusMessage = e.message;
      });
      await _writeDashboardStatus(
        status: 'blocked',
        progressLabel: 'Manifest build failed.',
        taskTitle: 'Manifest build error',
        taskSummary: e.message,
        checkpoint: 'Retry Build Manifest',
        eventType: 'error',
        eventMessage: 'Manifest build failed: ${e.message}',
        isBlocked: true,
      );
    } catch (e) {
      setState(() {
        _manifestResult = null;
        _statusMessage = 'Error running Rust:\n\n$e';
      });
      await _writeDashboardStatus(
        status: 'blocked',
        progressLabel: 'Unexpected runtime error.',
        taskTitle: 'Runtime error',
        taskSummary: 'Error running Rust: $e',
        checkpoint: 'Retry Build Manifest',
        eventType: 'error',
        eventMessage: 'Unexpected runtime error: $e',
        isBlocked: true,
      );
    } finally {
      setState(() {
        _isRunning = false;
      });
    }
  }

  Future<void> _runInventory(String folderPath) async {
    setState(() {
      _isInventoryRunning = true;
    });

    try {
      final result = await _manifestService.buildInventory(folderPath);
      setState(() {
        _inventoryResult = result;
        _selectedExtensions = result.extensions.map((s) => s.extension).toSet();
        _statusMessage =
            'Ready. ${result.totalFiles} files found — adjust scope then build manifest.';
      });
    } on ManifestServiceException catch (e) {
      setState(() {
        _statusMessage = e.message;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Error running inventory:\n\n$e';
      });
    } finally {
      setState(() {
        _isInventoryRunning = false;
      });
    }
  }

  int get _totalInventoryBytes =>
      _inventoryResult?.extensions.fold<int>(0, (s, e) => s + e.totalBytes) ??
      0;

  int get _uniqueFileCount {
    final result = _manifestResult;
    if (result == null) return 0;
    final duplicated =
        result.duplicateGroups.expand((g) => g).toSet().length;
    return result.totalFiles - duplicated;
  }

  int get _duplicateFileCount {
    final result = _manifestResult;
    if (result == null) return 0;
    return result.duplicateGroups.expand((g) => g).toSet().length;
  }

  IconData _iconForEntryType(String entryType) {
    switch (entryType) {
      case 'directory':
        return Icons.folder;
      case 'file':
        return Icons.insert_drive_file;
      default:
        return Icons.help_outline;
    }
  }

  String _formatSize(int? sizeBytes) {
    if (sizeBytes == null) {
      return '';
    }
    if (sizeBytes < 1024) {
      return '$sizeBytes B';
    }
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    if (sizeBytes < 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Widget _buildSummaryCard(ManifestResult result) {
    final int totalEntries = result.entries.length;
    final int duplicateGroupCount = result.duplicateGroups.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 24,
          runSpacing: 16,
          alignment: WrapAlignment.spaceEvenly,
          children: <Widget>[
            _SummaryItem(label: 'Entries', value: totalEntries.toString()),
            _SummaryItem(
              label: 'Folders',
              value: result.totalDirectories.toString(),
            ),
            _SummaryItem(label: 'Files', value: result.totalFiles.toString()),
            _SummaryItem(
              label: 'Dup. Groups',
              value: duplicateGroupCount.toString(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDuplicateGroups(ManifestResult result) {
    if (result.duplicateGroups.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 16),
        Text(
          'Duplicate Groups (${result.duplicateGroups.length})',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        ...result.duplicateGroups.asMap().entries.map((entry) {
          final int index = entry.key;
          final List<String> group = entry.value;
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Group ${index + 1} — ${group.length} identical files',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  ...group.map(
                    (path) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: <Widget>[
                          const Icon(
                            Icons.content_copy,
                            size: 14,
                            color: Colors.orange,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              path,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildManifestTile(ManifestEntry entry) {
    final double leftIndent = entry.depth * 20.0;

    String subtitle = entry.entryType;
    if (entry.parentPath.isNotEmpty) {
      subtitle = '${entry.parentPath} • $subtitle';
    }
    if (entry.sizeBytes != null) {
      subtitle = '$subtitle • ${_formatSize(entry.sizeBytes)}';
    }

    return Padding(
      padding: EdgeInsets.only(left: leftIndent),
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(_iconForEntryType(entry.entryType)),
        title: Text(entry.leafName),
        subtitle: Text(subtitle),
      ),
    );
  }

  List<ManifestEntry> get _visibleEntries {
    final manifestResult = _manifestResult;
    if (manifestResult == null) {
      return <ManifestEntry>[];
    }

    return filterManifestEntries(
      entries: manifestResult.entries,
      filter: _entryFilter,
      query: _searchQuery,
    );
  }

  Widget _buildReviewControls(ManifestResult result) {
    final visibleEntries = _visibleEntries;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text(
          'Review manifest',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            labelText: 'Search paths',
            hintText: 'Filter by relative path',
            border: const OutlineInputBorder(),
            suffixIcon: _searchQuery.trim().isEmpty
                ? null
                : IconButton(
                    onPressed: _searchController.clear,
                    icon: const Icon(Icons.clear),
                    tooltip: 'Clear search',
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            ChoiceChip(
              label: const Text('All'),
              selected: _entryFilter == ManifestEntryFilter.all,
              onSelected: (_) {
                setState(() {
                  _entryFilter = ManifestEntryFilter.all;
                });
              },
            ),
            ChoiceChip(
              label: const Text('Folders'),
              selected: _entryFilter == ManifestEntryFilter.directories,
              onSelected: (_) {
                setState(() {
                  _entryFilter = ManifestEntryFilter.directories;
                });
              },
            ),
            ChoiceChip(
              label: const Text('Files'),
              selected: _entryFilter == ManifestEntryFilter.files,
              onSelected: (_) {
                setState(() {
                  _entryFilter = ManifestEntryFilter.files;
                });
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Showing ${visibleEntries.length} of ${result.entries.length} entries',
          style: const TextStyle(fontSize: 16),
        ),
      ],
    );
  }

  Widget _buildScanSummaryCard() {
    final inventory = _inventoryResult;
    if (inventory == null) return const SizedBox.shrink();

    final hasScan = _manifestResult != null;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            onTap: () =>
                setState(() => _sourcesExpanded = !_sourcesExpanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: <Widget>[
                  const Text(
                    'Scan Summary',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _sourcesExpanded
                        ? 'Collapse ▴'
                        : 'Expand for Source Details ▾',
                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Wrap(
              spacing: 24,
              runSpacing: 16,
              alignment: WrapAlignment.spaceEvenly,
              children: <Widget>[
                _SummaryItem(
                  label: 'Files',
                  value: inventory.totalFiles.toString(),
                ),
                _SummaryItem(
                  label: 'Size',
                  value: _formatSize(_totalInventoryBytes),
                ),
                if (hasScan) ...<Widget>[
                  _SummaryItem(
                    label: 'Unique',
                    value: _uniqueFileCount.toString(),
                    color: Colors.green[700],
                  ),
                  _SummaryItem(
                    label: 'Duplicates',
                    value: _duplicateFileCount.toString(),
                    color: Colors.orange[700],
                  ),
                ],
              ],
            ),
          ),
          if (_sourcesExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: _buildSourceDetailCard(inventory),
            ),
        ],
      ),
    );
  }

  Widget _buildSourceDetailCard(InventoryResult inventory) {
    return Card(
      color: Colors.grey[50],
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.grey[300]!),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 24,
          runSpacing: 12,
          alignment: WrapAlignment.spaceEvenly,
          children: <Widget>[
            _SummaryItem(
              label: 'Files',
              value: inventory.totalFiles.toString(),
            ),
            _SummaryItem(
              label: 'Size',
              value: _formatSize(_totalInventoryBytes),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanScopeCard() {
    final inventory = _inventoryResult;
    if (inventory == null || inventory.extensions.isEmpty) {
      return const SizedBox.shrink();
    }

    final maxCount = inventory.extensions.fold<int>(
      0,
      (m, s) => s.count > m ? s.count : m,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Scan Scope',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Select the file types to include in all analysis passes.',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            const SizedBox(height: 12),
            ...inventory.extensions.map((stat) {
              final label =
                  stat.extension.isEmpty ? '(no extension)' : stat.extension;
              final isSelected = _selectedExtensions.contains(stat.extension);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: isSelected,
                        onChanged: (checked) {
                          setState(() {
                            if (checked == true) {
                              _selectedExtensions.add(stat.extension);
                            } else {
                              _selectedExtensions.remove(stat.extension);
                            }
                          });
                        },
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 72,
                      child: Text(
                        label,
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: maxCount > 0 ? stat.count / maxCount : 0,
                        backgroundColor: Colors.grey[200],
                        color: isSelected ? Colors.blue : Colors.grey[400],
                        minHeight: 6,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${stat.count}  ${_formatSize(stat.totalBytes)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[700],
                      ),
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

  List<Widget> _buildResultWidgets() {
    final manifestResult = _manifestResult;
    if (manifestResult == null) {
      return <Widget>[];
    }

    final visibleEntries = _visibleEntries;

    return <Widget>[
      Text(
        'Exists: ${manifestResult.exists ? "yes" : "no"}',
        style: const TextStyle(fontSize: 16),
      ),
      const SizedBox(height: 8),
      Text(
        'Is directory: ${manifestResult.isDirectory ? "yes" : "no"}',
        style: const TextStyle(fontSize: 16),
      ),
      const SizedBox(height: 16),
      _buildSummaryCard(manifestResult),
      const SizedBox(height: 16),
      _buildReviewControls(manifestResult),
      const SizedBox(height: 16),
      const Text(
        'Recursive manifest',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      if (manifestResult.entries.isEmpty)
        const Text(
          'This folder contains no recursive entries.',
          style: TextStyle(fontSize: 16),
        )
      else if (visibleEntries.isEmpty)
        const Text(
          'No entries match the current review filters.',
          style: TextStyle(fontSize: 16),
        )
      else
        ...visibleEntries.map(_buildManifestTile),
      _buildDuplicateGroups(manifestResult),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final String displayedPath = _selectedFolderPath ?? 'No folder selected';

    return Scaffold(
      appBar: AppBar(title: const Text('FileSteward')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Selected folder',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(displayedPath, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 24),
            Text(_statusMessage, style: const TextStyle(fontSize: 16)),
            if (_isInventoryRunning)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: LinearProgressIndicator(),
              ),
            if (_inventoryResult != null) ...<Widget>[
              const SizedBox(height: 24),
              _buildScanSummaryCard(),
              const SizedBox(height: 16),
              _buildScanScopeCard(),
            ],
            const SizedBox(height: 24),
            ..._buildResultWidgets(),
          ],
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Row(
          children: <Widget>[
            Expanded(
              child: ElevatedButton(
                onPressed: _chooseFolder,
                child: const Text('Choose Folder'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: ElevatedButton(
                onPressed: _isRunning ? null : _buildManifest,
                child: Text(_isRunning ? 'Running...' : 'Build Manifest'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _SummaryItem({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

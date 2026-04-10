import 'dart:io';

import 'package:flutter/material.dart';

import 'consolidate_models.dart';
import 'consolidate_service.dart';

// ---------------------------------------------------------------------------
// ConsolidateScan1Screen
//
// Phase 1 — Structure scan (no hashing).
//
// Layout:
//   • Stats band      — total files, source count, shared structures, file types
//   • File type ribbon — horizontally scrollable chips; tap to exclude
//   • Two-panel view  — Sources (left, Finder-style lazy tree per folder)
//                       | Proposed Target (right, merged lazy tree)
//   • Bottom bar      — exclusion count + "Scan File Contents" button
// ---------------------------------------------------------------------------

class ConsolidateScan1Screen extends StatefulWidget {
  const ConsolidateScan1Screen({
    super.key,
    required this.sourceFolders,
    required this.service,
    required this.onProceed,
    required this.onBack,
  });

  final List<String> sourceFolders;
  final ConsolidateService service;

  final void Function({
    required List<String> excludedExtensions,
    required List<String> excludedFolders,
    required List<String> overriddenPaths,
  }) onProceed;

  final VoidCallback onBack;

  @override
  State<ConsolidateScan1Screen> createState() => _ConsolidateScan1ScreenState();
}

class _ConsolidateScan1ScreenState extends State<ConsolidateScan1Screen> {
  bool _scanning = true;
  StructureScanComplete? _result;
  String? _error;

  // Absolute paths (files + folders) excluded by tree right-click.
  final Set<String> _excludedPaths = {};
  // Extensions WITH leading dot, e.g. '.jpg'. Unified between ribbon chips
  // and tree context menus.
  final Set<String> _excludedExtensions = {};
  // Absolute paths explicitly re-included despite extension exclusion.
  final Set<String> _includedPaths = {};

  final ScrollController _ribbonController = ScrollController();

  static const _folderColors = [
    Color(0xFF0E70C0),
    Color(0xFF0A7764),
    Color(0xFF7B3FB5),
    Color(0xFFB85C00),
  ];

  Color _colorFor(int index) => _folderColors[index % _folderColors.length];

  @override
  void initState() {
    super.initState();
    _runScan();
  }

  @override
  void dispose() {
    _ribbonController.dispose();
    super.dispose();
  }

  void _runScan() {
    widget.service.structureScan(folders: widget.sourceFolders).listen(
      (event) {
        if (!mounted) return;
        if (event is StructureScanComplete) {
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
  // Exclusion callbacks (passed down to tree panels)
  // ---------------------------------------------------------------------------

  void _excludePath(String absPath) => setState(() {
    _excludedPaths.add(absPath);
    _includedPaths.remove(absPath); // clear any prior include override
  });

  void _includePath(String absPath) => setState(() {
    _excludedPaths.remove(absPath);
    _includedPaths.add(absPath); // path-level override beats extension exclusion
  });

  // ext has leading dot, e.g. '.jpg'
  void _excludeExt(String ext) => setState(() => _excludedExtensions.add(ext));

  // Called from the ribbon chips — extNoDot has no leading dot (from Rust).
  void _toggleRibbonExtension(String extNoDot) {
    final ext = '.$extNoDot';
    setState(() {
      if (_excludedExtensions.contains(ext)) {
        _excludedExtensions.remove(ext);
      } else {
        _excludedExtensions.add(ext);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Proceed
  // ---------------------------------------------------------------------------

  void _proceed() {
    // Convert absolute excluded paths to relative-path prefixes for Rust.
    final excludedRelFolders = <String>{};
    for (final abs in _excludedPaths) {
      for (final src in widget.sourceFolders) {
        if (abs.startsWith('$src/')) {
          excludedRelFolders.add(abs.substring(src.length + 1));
          break;
        }
      }
    }

    // Convert included path overrides to relative paths for Rust.
    final overriddenRel = <String>{};
    for (final abs in _includedPaths) {
      for (final src in widget.sourceFolders) {
        if (abs.startsWith('$src/')) {
          overriddenRel.add(abs.substring(src.length + 1));
          break;
        }
      }
    }

    widget.onProceed(
      excludedExtensions: _excludedExtensions
          .map((e) => e.startsWith('.') ? e.substring(1) : e)
          .toList(),
      excludedFolders: excludedRelFolders.toList(),
      overriddenPaths: overriddenRel.toList(),
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
        if (_scanning) _buildScanning(),
        if (_error != null) _buildError(),
        if (_result != null && !_scanning) ...[
          _buildStatsband(_result!),
          _buildTypeRibbon(_result!),
          const Divider(height: 1),
          Expanded(child: _buildTwoPanels()),
          _buildBottomBar(),
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
                tooltip: 'Back',
              ),
              const SizedBox(width: 8),
              const Text(
                'Step 2: Filter',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const Divider(height: 20),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Scanning / error states
  // ---------------------------------------------------------------------------

  Widget _buildScanning() {
    return const Expanded(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Scanning folder structure…', style: TextStyle(fontSize: 14)),
          ],
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

  // ---------------------------------------------------------------------------
  // Stats band
  // ---------------------------------------------------------------------------

  Widget _buildStatsband(StructureScanComplete result) {
    return Container(
      color: Colors.blue.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStat('Total Files', '${result.totalFiles}'),
          _buildStat('Sources', '${result.sourceFolders.length}'),
          _buildStat('Shared Structures', '${result.folderGroups.length}'),
          _buildStat('File Types', '${result.fileTypeCounts.length}'),
        ],
      ),
    );
  }

  Widget _buildStat(String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // File type ribbon
  // ---------------------------------------------------------------------------

  Widget _buildTypeRibbon(StructureScanComplete result) {
    final types = [...result.fileTypeCounts]
      ..sort((a, b) => b.count.compareTo(a.count));

    void scrollLeft() {
      _ribbonController.animateTo(
        (_ribbonController.offset - 200).clamp(0, double.infinity),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }

    void scrollRight() {
      _ribbonController.animateTo(
        _ribbonController.offset + 200,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }

    return Container(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 20, bottom: 6),
            child: Row(
              children: [
                const Text('File Types',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.black54)),
                const SizedBox(width: 8),
                Text('Tap to exclude',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ],
            ),
          ),
          // Chips row with arrow buttons
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 34),
                onPressed: scrollLeft,
                tooltip: 'Scroll left',
              ),
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: ListView.separated(
                    controller: _ribbonController,
                    scrollDirection: Axis.horizontal,
                    itemCount: types.length,
                    separatorBuilder: (context, i) => const SizedBox(width: 6),
                    itemBuilder: (context, i) {
                      final ft = types[i];
                      final excluded = _excludedExtensions.contains('.${ft.extension}');
                      return FilterChip(
                        label: Text(
                          '.${ft.extension}  ${ft.count}',
                          style: TextStyle(
                              fontSize: 11, color: excluded ? Colors.grey : null),
                        ),
                        selected: !excluded,
                        onSelected: (_) => _toggleRibbonExtension(ft.extension),
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        selectedColor: Colors.blue.shade50,
                        side: BorderSide(
                          color: excluded
                              ? Colors.grey.shade300
                              : Colors.blue.shade200,
                        ),
                      );
                    },
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 34),
                onPressed: scrollRight,
                tooltip: 'Scroll right',
              ),
            ],
          ),
          // Scrollbar beneath chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Scrollbar(
              controller: _ribbonController,
              thumbVisibility: true,
              child: const SizedBox(height: 8),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Two-panel view — Finder-style lazy trees
  // ---------------------------------------------------------------------------

  Widget _buildTwoPanels() {
    final colors = List.generate(widget.sourceFolders.length, _colorFor);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left — one navigable tree per source folder
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildPanelHeader(
                'Sources',
                '${widget.sourceFolders.length} folder${widget.sourceFolders.length == 1 ? "" : "s"} — right-click to exclude',
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (int i = 0; i < widget.sourceFolders.length; i++)
                      _SourceTreePanel(
                        key: ValueKey(widget.sourceFolders[i]),
                        folder: widget.sourceFolders[i],
                        folderIndex: i,
                        color: _colorFor(i),
                        excludedPaths: _excludedPaths,
                        excludedExtensions: _excludedExtensions,
                        includedPaths: _includedPaths,
                        onExcludePath: _excludePath,
                        onIncludePath: _includePath,
                        onExcludeExt: _excludeExt,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        VerticalDivider(width: 1, color: Colors.grey.shade200),
        // Right — merged target tree
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildPanelHeader('Proposed Target', 'merged view'),
              Expanded(
                child: _MergedTreePanel(
                  folders: widget.sourceFolders,
                  colors: colors,
                  excludedPaths: _excludedPaths,
                  excludedExtensions: _excludedExtensions,
                  includedPaths: _includedPaths,
                  onExcludePath: _excludePath,
                  onIncludePath: _includePath,
                  onExcludeExt: _excludeExt,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Panel header
  // ---------------------------------------------------------------------------

  Widget _buildPanelHeader(String title, String subtitle) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          Text(title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(subtitle,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Bottom bar
  // ---------------------------------------------------------------------------

  Widget _buildBottomBar() {
    final excludedCount = _excludedPaths.length + _excludedExtensions.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          if (excludedCount > 0)
            Text(
              '$excludedCount exclusion(s) selected',
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            )
          else
            const Text(
              'No exclusions — all files will be scanned',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
          const Spacer(),
          FilledButton.icon(
            onPressed: _proceed,
            icon: const Icon(Icons.search, size: 18),
            label: const Text('Scan File Contents'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tree data model
// ---------------------------------------------------------------------------

/// A node in a single-source directory tree (left panel).
class _SourceNode {
  final String name;
  final String path; // absolute
  final bool isDir;
  List<_SourceNode>? children; // null = not yet loaded
  bool isExpanded;

  _SourceNode({required this.name, required this.path, required this.isDir})
      : isExpanded = false;
}

/// A node in the merged target tree (right panel).
class _MergedNode {
  final String name;
  final String relPath; // relative path from any source root
  final bool isDir;
  final Set<int> sourceIndices; // which source folders have this path
  List<_MergedNode>? children; // null = not yet loaded
  bool isExpanded;

  _MergedNode({
    required this.name,
    required this.relPath,
    required this.isDir,
    required this.sourceIndices,
  }) : isExpanded = false;
}

/// Actions available on a tree node context menu.
enum _TreeAction { excludeFile, excludeExt, excludeFolder, include }

// ---------------------------------------------------------------------------
// Lazy directory loader helpers
// ---------------------------------------------------------------------------

List<_SourceNode> _loadSourceChildren(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return [];
  try {
    final entities = dir.listSync(recursive: false, followLinks: false)
      ..sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return a.path.split('/').last
            .toLowerCase()
            .compareTo(b.path.split('/').last.toLowerCase());
      });
    return entities
        .where((e) => !e.path.split('/').last.startsWith('.'))
        .map((e) => _SourceNode(
              name: e.path.split('/').last,
              path: e.path,
              isDir: e is Directory,
            ))
        .toList();
  } catch (_) {
    return [];
  }
}

List<_MergedNode> _buildMergedChildren(
    String relPath, List<String> sourceFolders) {
  final nameToSources = <String, Set<int>>{};
  final nameIsDir = <String, bool>{};

  for (int i = 0; i < sourceFolders.length; i++) {
    final dirPath =
        relPath.isEmpty ? sourceFolders[i] : '${sourceFolders[i]}/$relPath';
    final dir = Directory(dirPath);
    if (!dir.existsSync()) continue;
    try {
      for (final entity in dir.listSync(recursive: false, followLinks: false)) {
        final name = entity.path.split('/').last;
        if (name.startsWith('.')) continue;
        nameToSources.putIfAbsent(name, () => {}).add(i);
        nameIsDir[name] = (nameIsDir[name] ?? false) || entity is Directory;
      }
    } catch (_) {}
  }

  final entries = nameToSources.entries.toList()
    ..sort((a, b) {
      final aDir = nameIsDir[a.key] ?? false;
      final bDir = nameIsDir[b.key] ?? false;
      if (aDir != bDir) return aDir ? -1 : 1;
      return a.key.toLowerCase().compareTo(b.key.toLowerCase());
    });

  return entries.map((e) {
    final childRel = relPath.isEmpty ? e.key : '$relPath/${e.key}';
    return _MergedNode(
      name: e.key,
      relPath: childRel,
      isDir: nameIsDir[e.key] ?? false,
      sourceIndices: e.value,
    );
  }).toList();
}

// ---------------------------------------------------------------------------
// _SourceTreePanel — one source folder tree (left panel)
// ---------------------------------------------------------------------------

class _SourceTreePanel extends StatefulWidget {
  final String folder;
  final int folderIndex;
  final Color color;
  final Set<String> excludedPaths;
  final Set<String> excludedExtensions;
  final Set<String> includedPaths;
  final void Function(String) onExcludePath;
  final void Function(String) onIncludePath;
  final void Function(String) onExcludeExt;

  const _SourceTreePanel({
    super.key,
    required this.folder,
    required this.folderIndex,
    required this.color,
    required this.excludedPaths,
    required this.excludedExtensions,
    required this.includedPaths,
    required this.onExcludePath,
    required this.onIncludePath,
    required this.onExcludeExt,
  });

  @override
  State<_SourceTreePanel> createState() => _SourceTreePanelState();
}

class _SourceTreePanelState extends State<_SourceTreePanel> {
  late _SourceNode _root;

  @override
  void initState() {
    super.initState();
    _root = _SourceNode(
        name: widget.folder.split('/').last,
        path: widget.folder,
        isDir: true);
    _root.isExpanded = true;
    _root.children = _loadSourceChildren(widget.folder);
  }

  void _toggle(_SourceNode node) {
    setState(() {
      if (!node.isExpanded) {
        node.children ??= _loadSourceChildren(node.path);
      }
      node.isExpanded = !node.isExpanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Folder header strip
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: 0.06),
            border: Border(
                bottom:
                    BorderSide(color: widget.color.withValues(alpha: 0.3))),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: 7),
                decoration:
                    BoxDecoration(color: widget.color, shape: BoxShape.circle),
              ),
              Text(
                'Folder ${widget.folderIndex + 1}',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: widget.color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.folder,
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        // Tree nodes
        ..._buildNodeList(_root.children ?? [], depth: 0),
      ],
    );
  }

  List<Widget> _buildNodeList(List<_SourceNode> nodes, {required int depth}) {
    final widgets = <Widget>[];
    for (final node in nodes) {
      final ext = node.isDir
          ? ''
          : node.name.contains('.')
              ? '.${node.name.split('.').last.toLowerCase()}'
              : '';
      final isExcluded = (widget.excludedPaths.contains(node.path) ||
          (!node.isDir && widget.excludedExtensions.contains(ext))) &&
          !widget.includedPaths.contains(node.path);

      widgets.add(_TreeNodeRow(
        name: node.name,
        isDir: node.isDir,
        isExpanded: node.isExpanded,
        isExcluded: isExcluded,
        depth: depth,
        accentColor: widget.color,
        onTap: node.isDir ? () => _toggle(node) : null,
        contextItems: _contextItems(node, isExcluded, ext),
        onContextAction: (action) => _handleAction(action, node, ext),
      ));

      if (node.isDir && node.isExpanded && node.children != null) {
        widgets.addAll(_buildNodeList(node.children!, depth: depth + 1));
      }
    }
    return widgets;
  }

  List<PopupMenuEntry<_TreeAction>> _contextItems(
      _SourceNode node, bool isExcluded, String ext) {
    if (isExcluded) {
      return [
        const PopupMenuItem(
            value: _TreeAction.include, child: Text('Include again')),
      ];
    }
    if (node.isDir) {
      return [
        const PopupMenuItem(
            value: _TreeAction.excludeFolder,
            child: Text('Exclude this folder')),
      ];
    }
    return [
      const PopupMenuItem(
          value: _TreeAction.excludeFile, child: Text('Exclude this file')),
      if (ext.isNotEmpty)
        PopupMenuItem(
            value: _TreeAction.excludeExt,
            child: Text('Exclude all $ext files')),
    ];
  }

  void _handleAction(_TreeAction action, _SourceNode node, String ext) {
    switch (action) {
      case _TreeAction.excludeFile:
      case _TreeAction.excludeFolder:
        widget.onExcludePath(node.path);
      case _TreeAction.excludeExt:
        widget.onExcludeExt(ext);
      case _TreeAction.include:
        widget.onIncludePath(node.path);
    }
  }
}

// ---------------------------------------------------------------------------
// _MergedTreePanel — merged target tree (right panel)
// ---------------------------------------------------------------------------

class _MergedTreePanel extends StatefulWidget {
  final List<String> folders;
  final List<Color> colors;
  final Set<String> excludedPaths;
  final Set<String> excludedExtensions;
  final Set<String> includedPaths;
  final void Function(String) onExcludePath;
  final void Function(String) onIncludePath;
  final void Function(String) onExcludeExt;

  const _MergedTreePanel({
    super.key,
    required this.folders,
    required this.colors,
    required this.excludedPaths,
    required this.excludedExtensions,
    required this.includedPaths,
    required this.onExcludePath,
    required this.onIncludePath,
    required this.onExcludeExt,
  });

  @override
  State<_MergedTreePanel> createState() => _MergedTreePanelState();
}

class _MergedTreePanelState extends State<_MergedTreePanel> {
  List<_MergedNode> _roots = [];

  @override
  void initState() {
    super.initState();
    _roots = _buildMergedChildren('', widget.folders);
  }

  void _toggle(_MergedNode node) {
    setState(() {
      if (!node.isExpanded) {
        node.children ??= _buildMergedChildren(node.relPath, widget.folders);
      }
      node.isExpanded = !node.isExpanded;
    });
  }

  bool _isExcluded(_MergedNode node) {
    final ext = node.isDir
        ? ''
        : node.name.contains('.')
            ? '.${node.name.split('.').last.toLowerCase()}'
            : '';
    final allSourcePaths =
        node.sourceIndices.map((i) => '${widget.folders[i]}/${node.relPath}').toList();
    // A path-level include override beats any exclusion.
    if (allSourcePaths.any((p) => widget.includedPaths.contains(p))) return false;
    if (allSourcePaths.every((p) => widget.excludedPaths.contains(p))) return true;
    if (!node.isDir && widget.excludedExtensions.contains(ext)) return true;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_roots.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No files to preview.',
              style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: _buildNodeList(_roots, depth: 0),
    );
  }

  List<Widget> _buildNodeList(List<_MergedNode> nodes, {required int depth}) {
    final widgets = <Widget>[];
    for (final node in nodes) {
      final excluded = _isExcluded(node);
      final ext = node.isDir
          ? ''
          : node.name.contains('.')
              ? '.${node.name.split('.').last.toLowerCase()}'
              : '';

      final dots = node.sourceIndices
          .where((i) => i < widget.colors.length)
          .map((i) => widget.colors[i])
          .toList();

      widgets.add(_TreeNodeRow(
        name: node.name,
        isDir: node.isDir,
        isExpanded: node.isExpanded,
        isExcluded: excluded,
        depth: depth,
        accentColor: Colors.grey[700]!,
        sourceDots: dots,
        onTap: node.isDir ? () => _toggle(node) : null,
        contextItems: _contextItems(node, excluded, ext),
        onContextAction: (action) => _handleAction(action, node, ext),
      ));

      if (node.isDir && node.isExpanded && node.children != null) {
        widgets.addAll(_buildNodeList(node.children!, depth: depth + 1));
      }
    }
    return widgets;
  }

  List<PopupMenuEntry<_TreeAction>> _contextItems(
      _MergedNode node, bool excluded, String ext) {
    if (excluded) {
      return [
        const PopupMenuItem(
            value: _TreeAction.include, child: Text('Include again')),
      ];
    }
    if (node.isDir) {
      return [
        const PopupMenuItem(
            value: _TreeAction.excludeFolder,
            child: Text('Exclude this folder')),
      ];
    }
    return [
      const PopupMenuItem(
          value: _TreeAction.excludeFile, child: Text('Exclude this file')),
      if (ext.isNotEmpty)
        PopupMenuItem(
            value: _TreeAction.excludeExt,
            child: Text('Exclude all $ext files')),
    ];
  }

  void _handleAction(_TreeAction action, _MergedNode node, String ext) {
    switch (action) {
      case _TreeAction.excludeFile:
      case _TreeAction.excludeFolder:
        for (final i in node.sourceIndices) {
          widget.onExcludePath('${widget.folders[i]}/${node.relPath}');
        }
      case _TreeAction.excludeExt:
        widget.onExcludeExt(ext);
      case _TreeAction.include:
        for (final i in node.sourceIndices) {
          widget.onIncludePath('${widget.folders[i]}/${node.relPath}');
        }
    }
  }
}

// ---------------------------------------------------------------------------
// _TreeNodeRow — one row in a tree panel
// ---------------------------------------------------------------------------

class _TreeNodeRow extends StatelessWidget {
  final String name;
  final bool isDir;
  final bool isExpanded;
  final bool isExcluded;
  final int depth;
  final Color accentColor;
  final List<Color>? sourceDots;
  final VoidCallback? onTap;
  final List<PopupMenuEntry<_TreeAction>> contextItems;
  final void Function(_TreeAction) onContextAction;

  const _TreeNodeRow({
    required this.name,
    required this.isDir,
    required this.isExpanded,
    required this.isExcluded,
    required this.depth,
    required this.accentColor,
    required this.contextItems,
    required this.onContextAction,
    this.sourceDots,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final indent = 8.0 + depth * 14.0;
    final textStyle = TextStyle(
      fontSize: 12,
      color: isExcluded ? Colors.grey[400] : null,
      decoration: isExcluded ? TextDecoration.lineThrough : null,
    );

    return GestureDetector(
      onSecondaryTapUp: contextItems.isEmpty
          ? null
          : (details) async {
              final action = await showMenu<_TreeAction>(
                context: context,
                position: RelativeRect.fromLTRB(
                  details.globalPosition.dx,
                  details.globalPosition.dy,
                  details.globalPosition.dx + 1,
                  details.globalPosition.dy + 1,
                ),
                items: contextItems,
              );
              if (action != null) onContextAction(action);
            },
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 22,
          child: Row(
            children: [
              SizedBox(width: indent),
              // Chevron / spacer
              if (isDir)
                Icon(
                  isExpanded ? Icons.expand_more : Icons.chevron_right,
                  size: 14,
                  color: Colors.grey[500],
                )
              else
                const SizedBox(width: 14),
              const SizedBox(width: 2),
              // File/folder icon
              Icon(
                isDir ? Icons.folder : Icons.insert_drive_file,
                size: 13,
                color: isExcluded
                    ? Colors.grey[300]
                    : isDir
                        ? Colors.amber[700]
                        : Colors.grey[500],
              ),
              const SizedBox(width: 4),
              // Name
              Expanded(
                child: Text(name,
                    style: textStyle, overflow: TextOverflow.ellipsis),
              ),
              // Source dots (merged panel only)
              if (sourceDots != null && sourceDots!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: sourceDots!
                        .map((c) => Container(
                              width: 6,
                              height: 6,
                              margin: const EdgeInsets.only(left: 3),
                              decoration: BoxDecoration(
                                  color: c, shape: BoxShape.circle),
                            ))
                        .toList(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

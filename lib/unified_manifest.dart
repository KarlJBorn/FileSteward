import 'manifest_models.dart';

/// A file entry with its absolute path and the source folder it came from.
class UnifiedEntry {
  final String absolutePath;
  final ManifestEntry entry;
  final String sourceFolder;

  const UnifiedEntry({
    required this.absolutePath,
    required this.entry,
    required this.sourceFolder,
  });
}

/// A group of identical files (same SHA-256) that appear in more than one
/// source folder — the highest-value finding in a multi-source scan.
class CrossSourceGroup {
  final String sha256;
  final List<UnifiedEntry> members;

  const CrossSourceGroup({required this.sha256, required this.members});
}

/// Merged view across all scanned source folders.
class UnifiedManifest {
  final List<ManifestResult> sources;

  /// Files whose identical content appears in two or more source folders.
  final List<CrossSourceGroup> crossSourceGroups;

  const UnifiedManifest({
    required this.sources,
    required this.crossSourceGroups,
  });

  /// Build a [UnifiedManifest] by merging [sources] and computing cross-source
  /// duplicate groups. Files with a null sha256 (unreadable) are excluded.
  factory UnifiedManifest.from(List<ManifestResult> sources) {
    // Map sha256 → all unified entries across all sources.
    final Map<String, List<UnifiedEntry>> byHash = {};

    for (final source in sources) {
      for (final entry in source.entries) {
        if (entry.entryType != 'file') continue;
        final hash = entry.sha256;
        if (hash == null) continue;

        final absolutePath = entry.relativePath.isEmpty
            ? source.selectedFolder
            : '${source.selectedFolder}/${entry.relativePath}';

        byHash
            .putIfAbsent(hash, () => [])
            .add(UnifiedEntry(
              absolutePath: absolutePath,
              entry: entry,
              sourceFolder: source.selectedFolder,
            ));
      }
    }

    // A cross-source group requires members from at least two distinct source
    // folders (same hash appearing twice in the same source is already covered
    // by that source's own duplicateGroups).
    final crossSourceGroups = byHash.entries
        .where((e) {
          final folders = e.value.map((m) => m.sourceFolder).toSet();
          return folders.length > 1;
        })
        .map((e) => CrossSourceGroup(sha256: e.key, members: e.value))
        .toList()
      ..sort((a, b) => a.members.first.absolutePath
          .compareTo(b.members.first.absolutePath));

    return UnifiedManifest(
      sources: sources,
      crossSourceGroups: crossSourceGroups,
    );
  }

  int get totalFiles => sources.fold(0, (sum, s) => sum + s.totalFiles);
  int get totalDirectories =>
      sources.fold(0, (sum, s) => sum + s.totalDirectories);
  int get crossSourceGroupCount => crossSourceGroups.length;
  int get withinSourceGroupCount =>
      sources.fold(0, (sum, s) => sum + s.duplicateGroups.length);
}

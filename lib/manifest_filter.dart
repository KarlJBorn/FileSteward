import 'manifest_models.dart';

enum ManifestEntryFilter { all, directories, files }

List<ManifestEntry> filterManifestEntries({
  required List<ManifestEntry> entries,
  required ManifestEntryFilter filter,
  required String query,
}) {
  final normalizedQuery = query.trim().toLowerCase();

  return entries.where((entry) {
    final matchesFilter = switch (filter) {
      ManifestEntryFilter.all => true,
      ManifestEntryFilter.directories => entry.entryType == 'directory',
      ManifestEntryFilter.files => entry.entryType == 'file',
    };

    if (!matchesFilter) {
      return false;
    }

    if (normalizedQuery.isEmpty) {
      return true;
    }

    return entry.relativePath.toLowerCase().contains(normalizedQuery);
  }).toList();
}

class ManifestEntry {
  final String relativePath;
  final String entryType;
  final int? sizeBytes;
  final String? sha256;
  final int? modifiedSecs;

  ManifestEntry({
    required this.relativePath,
    required this.entryType,
    required this.sizeBytes,
    this.sha256,
    this.modifiedSecs,
  });

  factory ManifestEntry.fromJson(Map<String, dynamic> json) {
    return ManifestEntry(
      relativePath: json['relative_path'] as String? ?? '',
      entryType: json['entry_type'] as String? ?? 'other',
      sizeBytes: json['size_bytes'] as int?,
      sha256: json['sha256'] as String?,
      modifiedSecs: json['modified_secs'] as int?,
    );
  }

  List<String> get pathParts =>
      relativePath.split('/').where((part) => part.isNotEmpty).toList();

  int get depth => pathParts.isEmpty ? 0 : pathParts.length - 1;

  String get leafName => pathParts.isEmpty ? relativePath : pathParts.last;

  String get parentPath {
    if (pathParts.length <= 1) {
      return '';
    }
    return pathParts.sublist(0, pathParts.length - 1).join('/');
  }
}

class ManifestResult {
  final String selectedFolder;
  final bool exists;
  final bool isDirectory;
  final int totalDirectories;
  final int totalFiles;
  final List<ManifestEntry> entries;
  final List<List<String>> duplicateGroups;

  ManifestResult({
    required this.selectedFolder,
    required this.exists,
    required this.isDirectory,
    required this.totalDirectories,
    required this.totalFiles,
    required this.entries,
    this.duplicateGroups = const [],
  });

  factory ManifestResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawEntries = json['entries'] as List<dynamic>? ?? [];

    final entries = rawEntries
        .map(
          (dynamic item) =>
              ManifestEntry.fromJson(item as Map<String, dynamic>),
        )
        .toList();

    entries.sort((a, b) {
      final pathCompare = a.relativePath.toLowerCase().compareTo(
        b.relativePath.toLowerCase(),
      );
      if (pathCompare != 0) {
        return pathCompare;
      }

      if (a.entryType == b.entryType) {
        return 0;
      }
      if (a.entryType == 'directory') {
        return -1;
      }
      if (b.entryType == 'directory') {
        return 1;
      }
      return a.entryType.compareTo(b.entryType);
    });

    final List<dynamic> rawGroups =
        json['duplicate_groups'] as List<dynamic>? ?? [];
    final duplicateGroups = rawGroups
        .map(
          (dynamic group) =>
              (group as List<dynamic>).map((e) => e as String).toList(),
        )
        .toList();

    return ManifestResult(
      selectedFolder: json['selected_folder'] as String? ?? '',
      exists: json['exists'] as bool? ?? false,
      isDirectory: json['is_directory'] as bool? ?? false,
      totalDirectories: json['total_directories'] as int? ?? 0,
      totalFiles: json['total_files'] as int? ?? 0,
      entries: entries,
      duplicateGroups: duplicateGroups,
    );
  }
}

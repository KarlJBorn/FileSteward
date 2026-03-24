import 'package:flutter_test/flutter_test.dart';

import 'package:filesteward/manifest_filter.dart';
import 'package:filesteward/manifest_models.dart';

void main() {
  final entries = <ManifestEntry>[
    ManifestEntry(
      relativePath: 'archive',
      entryType: 'directory',
      sizeBytes: null,
    ),
    ManifestEntry(
      relativePath: 'archive/report.txt',
      entryType: 'file',
      sizeBytes: 1200,
    ),
    ManifestEntry(
      relativePath: 'photos/IMG_0001.JPG',
      entryType: 'file',
      sizeBytes: 3200,
    ),
  ];

  test('filters entries by type', () {
    final directories = filterManifestEntries(
      entries: entries,
      filter: ManifestEntryFilter.directories,
      query: '',
    );
    final files = filterManifestEntries(
      entries: entries,
      filter: ManifestEntryFilter.files,
      query: '',
    );

    expect(directories.map((entry) => entry.relativePath), <String>['archive']);
    expect(files.map((entry) => entry.relativePath), <String>[
      'archive/report.txt',
      'photos/IMG_0001.JPG',
    ]);
  });

  test('filters entries by case-insensitive path query', () {
    final filtered = filterManifestEntries(
      entries: entries,
      filter: ManifestEntryFilter.all,
      query: 'img_0001',
    );

    expect(filtered.map((entry) => entry.relativePath), <String>[
      'photos/IMG_0001.JPG',
    ]);
  });
}

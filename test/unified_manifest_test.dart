import 'package:flutter_test/flutter_test.dart';

import 'package:filesteward/manifest_models.dart';
import 'package:filesteward/unified_manifest.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a minimal [ManifestResult] for testing.
ManifestResult makeSource({
  required String folder,
  required List<ManifestEntry> entries,
  List<List<String>> duplicateGroups = const [],
}) {
  final files = entries.where((e) => e.entryType == 'file').length;
  final dirs = entries.where((e) => e.entryType == 'directory').length;
  return ManifestResult(
    selectedFolder: folder,
    exists: true,
    isDirectory: true,
    totalFiles: files,
    totalDirectories: dirs,
    entries: entries,
    duplicateGroups: duplicateGroups,
  );
}

/// Build a file [ManifestEntry] with an optional sha256.
ManifestEntry makeFile(
  String relativePath, {
  String? sha256,
  int sizeBytes = 1024,
}) {
  return ManifestEntry(
    relativePath: relativePath,
    entryType: 'file',
    sizeBytes: sizeBytes,
    sha256: sha256,
    modifiedSecs: null,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('UnifiedManifest.from', () {
    test('produces no cross-source groups when sources are empty', () {
      final manifest = UnifiedManifest.from([]);
      expect(manifest.crossSourceGroups, isEmpty);
      expect(manifest.totalFiles, 0);
      expect(manifest.totalDirectories, 0);
    });

    test('produces no cross-source groups for a single source', () {
      final source = makeSource(
        folder: '/disk1',
        entries: [
          makeFile('photo.jpg', sha256: 'aabbcc'),
          makeFile('doc.pdf', sha256: 'ddeeff'),
        ],
      );
      final manifest = UnifiedManifest.from([source]);
      expect(manifest.crossSourceGroups, isEmpty);
    });

    test('detects a cross-source group when two sources share a hash', () {
      final source1 = makeSource(
        folder: '/disk1',
        entries: [makeFile('photo.jpg', sha256: 'aabbcc')],
      );
      final source2 = makeSource(
        folder: '/disk2',
        entries: [makeFile('photo.jpg', sha256: 'aabbcc')],
      );

      final manifest = UnifiedManifest.from([source1, source2]);

      expect(manifest.crossSourceGroups.length, 1);
      final group = manifest.crossSourceGroups.first;
      expect(group.sha256, 'aabbcc');
      expect(group.members.length, 2);
      expect(
        group.members.map((m) => m.sourceFolder).toSet(),
        {'/disk1', '/disk2'},
      );
    });

    test('does not treat within-source duplicates as cross-source', () {
      // Two files with the same hash inside the same source folder.
      final source = makeSource(
        folder: '/disk1',
        entries: [
          makeFile('copy1.jpg', sha256: 'aabbcc'),
          makeFile('copy2.jpg', sha256: 'aabbcc'),
        ],
        duplicateGroups: [
          ['copy1.jpg', 'copy2.jpg']
        ],
      );
      final manifest = UnifiedManifest.from([source]);
      // Cross-source groups should be empty — both copies are in the same source.
      expect(manifest.crossSourceGroups, isEmpty);
      // Within-source count should reflect the duplicate group from the source.
      expect(manifest.withinSourceGroupCount, 1);
    });

    test('absolute paths are constructed correctly', () {
      final source1 = makeSource(
        folder: '/Volumes/Disk1',
        entries: [makeFile('documents/report.pdf', sha256: 'ff1122')],
      );
      final source2 = makeSource(
        folder: '/Volumes/Disk2',
        entries: [makeFile('backup/report.pdf', sha256: 'ff1122')],
      );

      final manifest = UnifiedManifest.from([source1, source2]);
      final group = manifest.crossSourceGroups.first;

      final paths = group.members.map((m) => m.absolutePath).toSet();
      expect(paths, {
        '/Volumes/Disk1/documents/report.pdf',
        '/Volumes/Disk2/backup/report.pdf',
      });
    });

    test('files with null sha256 are excluded from cross-source detection', () {
      final source1 = makeSource(
        folder: '/disk1',
        entries: [makeFile('unreadable.dat', sha256: null)],
      );
      final source2 = makeSource(
        folder: '/disk2',
        entries: [makeFile('unreadable.dat', sha256: null)],
      );

      final manifest = UnifiedManifest.from([source1, source2]);
      // No hash → cannot compare → no group.
      expect(manifest.crossSourceGroups, isEmpty);
    });

    test('handles three sources where only two share a hash', () {
      final source1 = makeSource(
        folder: '/disk1',
        entries: [makeFile('photo.jpg', sha256: 'aabbcc')],
      );
      final source2 = makeSource(
        folder: '/disk2',
        entries: [makeFile('photo.jpg', sha256: 'aabbcc')],
      );
      final source3 = makeSource(
        folder: '/disk3',
        entries: [makeFile('other.jpg', sha256: 'xxyyzz')],
      );

      final manifest = UnifiedManifest.from([source1, source2, source3]);
      expect(manifest.crossSourceGroups.length, 1);
      expect(manifest.crossSourceGroups.first.members.length, 2);
    });

    test('totalFiles and totalDirectories sum across all sources', () {
      final source1 = makeSource(
        folder: '/disk1',
        entries: [makeFile('a.jpg', sha256: 'aa')],
      );
      final source2 = makeSource(
        folder: '/disk2',
        entries: [makeFile('b.jpg', sha256: 'bb'), makeFile('c.jpg', sha256: 'cc')],
      );

      final manifest = UnifiedManifest.from([source1, source2]);
      expect(manifest.totalFiles, 3);
    });

    test('crossSourceGroupCount matches number of cross-source groups', () {
      final source1 = makeSource(
        folder: '/disk1',
        entries: [
          makeFile('photo.jpg', sha256: 'aabbcc'),
          makeFile('doc.pdf', sha256: 'ddeeff'),
        ],
      );
      final source2 = makeSource(
        folder: '/disk2',
        entries: [
          makeFile('photo.jpg', sha256: 'aabbcc'),
          makeFile('doc.pdf', sha256: 'ddeeff'),
        ],
      );

      final manifest = UnifiedManifest.from([source1, source2]);
      expect(manifest.crossSourceGroupCount, 2);
    });
  });
}

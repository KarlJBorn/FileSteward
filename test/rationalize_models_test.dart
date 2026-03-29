import 'package:flutter_test/flutter_test.dart';

import 'package:filesteward/rationalize_models.dart';

void main() {
  // ── FindingType ────────────────────────────────────────────────────────────

  group('FindingType.fromJson', () {
    test('parses all known types', () {
      expect(FindingType.fromJson('empty_folder'), FindingType.emptyFolder);
      expect(FindingType.fromJson('naming_inconsistency'),
          FindingType.namingInconsistency);
      expect(FindingType.fromJson('misplaced_file'), FindingType.misplacedFile);
      expect(
          FindingType.fromJson('excessive_nesting'), FindingType.excessiveNesting);
    });

    test('falls back to emptyFolder for unknown value', () {
      expect(FindingType.fromJson('unknown_type'), FindingType.emptyFolder);
    });
  });

  // ── RationalizeFinding ─────────────────────────────────────────────────────

  group('RationalizeFinding.fromJson', () {
    test('parses a remove finding', () {
      final json = <String, dynamic>{
        'id': 'f1',
        'finding_type': 'empty_folder',
        'severity': 'issue',
        'path': 'Old Projects/Archive',
        'absolute_path': '/Users/karl/Documents/Old Projects/Archive',
        'display_name': 'Archive',
        'action': 'remove',
        'destination': null,
        'absolute_destination': null,
        'inference_basis': 'Folder contains no files',
        'triggered_by': null,
      };

      final f = RationalizeFinding.fromJson(json);
      expect(f.id, 'f1');
      expect(f.findingType, FindingType.emptyFolder);
      expect(f.severity, FindingSeverity.issue);
      expect(f.action, FindingAction.remove);
      expect(f.destination, isNull);
      expect(f.triggeredBy, isNull);
      expect(f.isDependent, isFalse);
    });

    test('parses a rename finding', () {
      final json = <String, dynamic>{
        'id': 'f2',
        'finding_type': 'naming_inconsistency',
        'severity': 'issue',
        'path': 'Media/photoArchive',
        'absolute_path': '/Users/karl/Documents/Media/photoArchive',
        'display_name': 'photoArchive',
        'action': 'rename',
        'destination': 'Media/Photo Archive',
        'absolute_destination': '/Users/karl/Documents/Media/Photo Archive',
        'inference_basis': 'Title Case used by 94% of sibling folders',
        'triggered_by': null,
      };

      final f = RationalizeFinding.fromJson(json);
      expect(f.action, FindingAction.rename);
      expect(f.destination, 'Media/Photo Archive');
    });

    test('parses a dependent (cascade) finding', () {
      final json = <String, dynamic>{
        'id': 'f5',
        'finding_type': 'empty_folder',
        'severity': 'issue',
        'path': 'Old Projects',
        'absolute_path': '/Users/karl/Documents/Old Projects',
        'display_name': 'Old Projects',
        'action': 'remove',
        'destination': null,
        'absolute_destination': null,
        'inference_basis': 'Will become empty if Archive (f1) is removed',
        'triggered_by': 'f1',
      };

      final f = RationalizeFinding.fromJson(json);
      expect(f.triggeredBy, 'f1');
      expect(f.isDependent, isTrue);
    });

    test('isFolder is false for misplaced_file', () {
      final json = <String, dynamic>{
        'id': 'f3',
        'finding_type': 'misplaced_file',
        'severity': 'warning',
        'path': 'Finance/invoice.pdf',
        'absolute_path': '/Users/karl/Documents/Finance/invoice.pdf',
        'display_name': 'invoice.pdf',
        'action': 'move',
        'destination': 'Finance/Invoices/invoice.pdf',
        'absolute_destination':
            '/Users/karl/Documents/Finance/Invoices/invoice.pdf',
        'inference_basis': '.pdf files appear in Finance/Invoices/',
        'triggered_by': null,
      };
      final f = RationalizeFinding.fromJson(json);
      expect(f.isFolder, isFalse);
    });
  });

  // ── FindingsPayload ────────────────────────────────────────────────────────

  group('FindingsPayload.fromJson', () {
    final sampleJson = <String, dynamic>{
      'type': 'findings',
      'selected_folder': '/Users/karl/Documents',
      'scanned_at': '2026-03-28T14:32:00Z',
      'total_folders': 312,
      'findings': [
        {
          'id': 'f1',
          'finding_type': 'empty_folder',
          'severity': 'issue',
          'path': 'Archive',
          'absolute_path': '/Users/karl/Documents/Archive',
          'display_name': 'Archive',
          'action': 'remove',
          'destination': null,
          'absolute_destination': null,
          'inference_basis': 'Folder contains no files',
          'triggered_by': null,
        },
        {
          'id': 'f2',
          'finding_type': 'naming_inconsistency',
          'severity': 'issue',
          'path': 'Media/photoArchive',
          'absolute_path': '/Users/karl/Documents/Media/photoArchive',
          'display_name': 'photoArchive',
          'action': 'rename',
          'destination': 'Media/Photo Archive',
          'absolute_destination': '/Users/karl/Documents/Media/Photo Archive',
          'inference_basis': 'Title Case used by 94% of siblings',
          'triggered_by': null,
        },
      ],
      'errors': [],
    };

    test('parses envelope fields', () {
      final p = FindingsPayload.fromJson(sampleJson);
      expect(p.selectedFolder, '/Users/karl/Documents');
      expect(p.scannedAt, '2026-03-28T14:32:00Z');
      expect(p.totalFolders, 312);
      expect(p.findings.length, 2);
      expect(p.errors, isEmpty);
    });

    test('byType groups findings correctly', () {
      final p = FindingsPayload.fromJson(sampleJson);
      final byType = p.byType;
      expect(byType[FindingType.emptyFolder]!.length, 1);
      expect(byType[FindingType.namingInconsistency]!.length, 1);
      expect(byType.containsKey(FindingType.misplacedFile), isFalse);
    });

    test('findById returns correct finding', () {
      final p = FindingsPayload.fromJson(sampleJson);
      expect(p.findById('f1')!.displayName, 'Archive');
      expect(p.findById('f2')!.displayName, 'photoArchive');
      expect(p.findById('f99'), isNull);
    });
  });

  // ── ExecutionPlan.toJson ───────────────────────────────────────────────────

  group('ExecutionPlan.toJson', () {
    test('serializes remove action without destination', () {
      final plan = ExecutionPlan(
        selectedFolder: '/Users/karl/Documents',
        sessionId: '2026-03-28T14-32-00',
        actions: [
          ExecutionActionItem(
            findingId: 'f1',
            action: FindingAction.remove,
            absolutePath: '/Users/karl/Documents/Archive',
          ),
        ],
      );

      final json = plan.toJson();
      expect(json['type'], 'execute');
      expect(json['session_id'], '2026-03-28T14-32-00');
      final actions = json['actions'] as List<dynamic>;
      expect(actions.length, 1);
      final a = actions[0] as Map<String, dynamic>;
      expect(a['finding_id'], 'f1');
      expect(a['action'], 'remove');
      expect(a.containsKey('absolute_destination'), isFalse);
    });

    test('serializes rename action with destination', () {
      final plan = ExecutionPlan(
        selectedFolder: '/Users/karl/Documents',
        sessionId: '2026-03-28T14-32-00',
        actions: [
          ExecutionActionItem(
            findingId: 'f2',
            action: FindingAction.rename,
            absolutePath: '/Users/karl/Documents/Media/photoArchive',
            absoluteDestination: '/Users/karl/Documents/Media/Photo Archive',
          ),
        ],
      );

      final json = plan.toJson();
      final actions = json['actions'] as List<dynamic>;
      final a = actions[0] as Map<String, dynamic>;
      expect(a['action'], 'rename');
      expect(a['absolute_destination'],
          '/Users/karl/Documents/Media/Photo Archive');
    });
  });

  // ── ExecutionResult.fromJson ───────────────────────────────────────────────

  group('ExecutionResult.fromJson', () {
    test('parses result envelope and entries', () {
      final json = <String, dynamic>{
        'type': 'execution_result',
        'session_id': '2026-03-28T14-32-00',
        'total': 2,
        'succeeded': 1,
        'skipped': 0,
        'failed': 1,
        'log_path':
            '/Users/karl/.filesteward/logs/2026-03-28T14-32-00.json',
        'quarantine_path':
            '/Users/karl/.filesteward/quarantine/2026-03-28T14-32-00',
        'entries': [
          {
            'finding_id': 'f1',
            'action': 'remove',
            'absolute_path': '/Users/karl/Documents/Archive',
            'absolute_destination':
                '/Users/karl/.filesteward/quarantine/2026-03-28T14-32-00/Archive',
            'outcome': 'succeeded',
            'error': null,
          },
          {
            'finding_id': 'f2',
            'action': 'rename',
            'absolute_path': '/Users/karl/Documents/Media/photoArchive',
            'absolute_destination':
                '/Users/karl/Documents/Media/Photo Archive',
            'outcome': 'failed',
            'error': 'Destination already exists',
          },
        ],
      };

      final r = ExecutionResult.fromJson(json);
      expect(r.sessionId, '2026-03-28T14-32-00');
      expect(r.total, 2);
      expect(r.succeeded, 1);
      expect(r.failed, 1);
      expect(r.entries.length, 2);
      expect(r.entries[0].outcome, ExecutionOutcome.succeeded);
      expect(r.entries[0].error, isNull);
      expect(r.entries[1].outcome, ExecutionOutcome.failed);
      expect(r.entries[1].error, 'Destination already exists');
    });
  });
}

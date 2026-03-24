import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final statusDir = _resolveStatusDirectory();
  stdout.writeln('Watching AgentBoard dev commands in ${statusDir.path}');

  while (true) {
    await _processPendingCommands(statusDir);
    await Future<void>.delayed(const Duration(seconds: 2));
  }
}

Directory _resolveStatusDirectory() {
  final override = Platform.environment['FILESTEWARD_AGENT_BOARD_DIR'];
  if (override != null && override.isNotEmpty) {
    return Directory(override);
  }

  final pwd = Platform.environment['PWD'];
  if (pwd != null && pwd.isNotEmpty) {
    return Directory('$pwd/dev_status');
  }

  return Directory('${Directory.current.path}/dev_status');
}

Future<void> _processPendingCommands(Directory statusDir) async {
  final commandsFile = File('${statusDir.path}/commands.jsonl');
  final receiptsFile = File('${statusDir.path}/command_receipts.jsonl');
  final snapshotFile = File('${statusDir.path}/current_run.json');
  final workLogFile = File('${statusDir.path}/work_log.jsonl');

  if (!await commandsFile.exists() || !await snapshotFile.exists()) {
    return;
  }

  final processedIds = <String>{};
  if (await receiptsFile.exists()) {
    final receiptLines = const LineSplitter()
        .convert(await receiptsFile.readAsString())
        .where((line) => line.trim().isNotEmpty);
    for (final line in receiptLines) {
      final decoded = jsonDecode(line) as Map<String, dynamic>;
      processedIds.add(decoded['command_id'] as String);
    }
  }

  final commandLines = const LineSplitter()
      .convert(await commandsFile.readAsString())
      .where((line) => line.trim().isNotEmpty);

  final commands =
      commandLines
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .where((command) => !processedIds.contains(command['id'] as String))
          .toList()
        ..sort(
          (left, right) => (left['created_at'] as String).compareTo(
            right['created_at'] as String,
          ),
        );

  for (final command in commands) {
    final snapshot =
        jsonDecode(await snapshotFile.readAsString()) as Map<String, dynamic>;
    final workLog = await _readExistingLog(workLogFile);
    final result = _applyCommand(snapshot: snapshot, command: command);

    await snapshotFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(result.snapshot),
    );
    await workLogFile.writeAsString(
      '${workLog.join('\n')}${workLog.isEmpty ? '' : '\n'}${jsonEncode(result.event)}\n',
    );
    await receiptsFile.writeAsString(
      '${jsonEncode(result.receipt)}\n',
      mode: FileMode.append,
    );
  }
}

Future<List<String>> _readExistingLog(File workLogFile) async {
  if (!await workLogFile.exists()) {
    return <String>[];
  }

  return const LineSplitter()
      .convert(await workLogFile.readAsString())
      .where((line) => line.trim().isNotEmpty)
      .toList();
}

_CommandResult _applyCommand({
  required Map<String, dynamic> snapshot,
  required Map<String, dynamic> command,
}) {
  final now = DateTime.now().toUtc().toIso8601String();
  final agents = (snapshot['agents'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final run = snapshot['run'] as Map<String, dynamic>;
  final reviewer = agents.firstWhere((agent) => agent['id'] == 'reviewer');
  final builder = agents.firstWhere((agent) => agent['id'] == 'builder');

  final commandId = command['id'] as String;
  final commandName = command['command'] as String;

  late final Map<String, dynamic> event;
  late final Map<String, dynamic> receipt;

  switch (commandName) {
    case 'approve':
      reviewer['status'] = 'completed';
      reviewer['progress_label'] =
          'Approval received. Reviewer is cleared to begin the next review pass.';
      reviewer['last_update_at'] = now;
      reviewer['estimated_remaining_minutes'] = 0;
      reviewer['current_task'] = <String, dynamic>{
        'title': 'Approval acknowledged',
        'summary':
            'Human approval received. Reviewer is ready for the next FileSteward development review.',
        'checkpoint': 'Start review on next task',
        'eta_at': now,
      };
      reviewer['blocker'] = <String, dynamic>{
        'is_blocked': false,
        'summary': 'No blocker',
        'requires_human': false,
      };
      reviewer['handoff'] = <String, dynamic>{
        'ready': true,
        'destination': 'Reviewer',
        'summary': 'Approval cleared. Waiting for the next review assignment.',
        'updated_at': now,
      };
      run['needs_approval_agents'] = 0;
      run['completed_agents'] = 3;
      run['updated_at'] = now;
      run['checkpoint_eta'] = now;
      event = <String, dynamic>{
        'id': 'dev-evt-${DateTime.now().microsecondsSinceEpoch}',
        'agent_id': 'reviewer',
        'timestamp': now,
        'type': 'approval',
        'message': 'Human approval was granted through AgentBoard.',
        'status': 'completed',
        'files': <String>[],
        'commands': <String>['approve'],
      };
      receipt = _receipt(
        commandId: commandId,
        outcome: 'processed',
        message: 'Approval applied to reviewer state.',
      );
      break;
    case 'retry':
      builder['status'] = 'working';
      builder['progress_label'] =
          'Retry requested. Builder is back in active implementation mode.';
      builder['last_update_at'] = now;
      builder['estimated_remaining_minutes'] = 15;
      builder['current_task'] = <String, dynamic>{
        'title': 'Retry implementation pass',
        'summary':
            'Builder has been asked to retry the current FileSteward development task.',
        'checkpoint': 'Emit fresh implementation checkpoint',
        'eta_at': now,
      };
      builder['handoff'] = <String, dynamic>{
        'ready': false,
        'destination': 'Reviewer',
        'summary': 'Retry in progress.',
        'updated_at': now,
      };
      run['active_agents'] = 1;
      run['completed_agents'] = 1;
      run['updated_at'] = now;
      run['checkpoint_eta'] = now;
      event = <String, dynamic>{
        'id': 'dev-evt-${DateTime.now().microsecondsSinceEpoch}',
        'agent_id': 'builder',
        'timestamp': now,
        'type': 'retry',
        'message':
            'Retry requested from AgentBoard. Builder returned to working state.',
        'status': 'working',
        'files': <String>[],
        'commands': <String>['retry'],
      };
      receipt = _receipt(
        commandId: commandId,
        outcome: 'processed',
        message: 'Retry applied to builder state.',
      );
      break;
    case 'request_checkpoint':
      run['updated_at'] = now;
      run['checkpoint_eta'] = now;
      event = <String, dynamic>{
        'id': 'dev-evt-${DateTime.now().microsecondsSinceEpoch}',
        'agent_id': command['agent_id'] as String,
        'timestamp': now,
        'type': 'checkpoint',
        'message':
            'Checkpoint requested from AgentBoard. Current development status was re-emitted.',
        'status': 'working',
        'files': <String>['dev_status/current_run.json'],
        'commands': <String>['request_checkpoint'],
      };
      receipt = _receipt(
        commandId: commandId,
        outcome: 'processed',
        message: 'Checkpoint event emitted.',
      );
      break;
    default:
      event = <String, dynamic>{
        'id': 'dev-evt-${DateTime.now().microsecondsSinceEpoch}',
        'agent_id': command['agent_id'] as String,
        'timestamp': now,
        'type': 'ignored',
        'message': 'Unknown command $commandName was ignored.',
        'status': 'waiting',
        'files': <String>[],
        'commands': <String>[commandName],
      };
      receipt = _receipt(
        commandId: commandId,
        outcome: 'ignored',
        message: 'Unknown command $commandName.',
      );
  }

  snapshot['generated_at'] = now;
  return _CommandResult(snapshot: snapshot, event: event, receipt: receipt);
}

Map<String, dynamic> _receipt({
  required String commandId,
  required String outcome,
  required String message,
}) {
  return <String, dynamic>{
    'command_id': commandId,
    'outcome': outcome,
    'message': message,
    'processed_at': DateTime.now().toUtc().toIso8601String(),
  };
}

class _CommandResult {
  const _CommandResult({
    required this.snapshot,
    required this.event,
    required this.receipt,
  });

  final Map<String, dynamic> snapshot;
  final Map<String, dynamic> event;
  final Map<String, dynamic> receipt;
}

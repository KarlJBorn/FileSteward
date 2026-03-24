import 'dart:convert';
import 'dart:io';

const String _schemaVersion = '1.1';
const String _roleId = 'filesteward';
const String _roleName = 'FileSteward';
const String _roleDescription = 'Manifest Builder';
const String _runtimeStatusSource = 'filesteward_app';

class AgentBoardCommand {
  const AgentBoardCommand({
    required this.id,
    required this.agentId,
    required this.command,
    required this.createdAt,
  });

  final String id;
  final String agentId;
  final String command;
  final DateTime createdAt;

  factory AgentBoardCommand.fromJson(Map<String, dynamic> json) {
    return AgentBoardCommand(
      id: json['id'] as String,
      agentId: json['agent_id'] as String,
      command: json['command'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

class AgentBoardStatusWriter {
  const AgentBoardStatusWriter({this.directoryResolver});

  final Directory Function()? directoryResolver;

  Future<void> writeStatus({
    required String status,
    required String progressLabel,
    required String taskTitle,
    required String taskSummary,
    required String checkpoint,
    required bool isBlocked,
    String? selectedFolderPath,
    List<String> filesTouched = const <String>[],
    List<String> commandsRun = const <String>[],
  }) async {
    final directory = await _resolveStatusDirectory();
    await directory.create(recursive: true);

    final now = DateTime.now().toUtc();
    final checkpointEta = now.add(const Duration(minutes: 10));

    final payload = <String, dynamic>{
      'schema_version': _schemaVersion,
      'generated_at': now.toIso8601String(),
      'source_directory': directory.path,
      'run': <String, dynamic>{
        'id': 'filesteward-dev',
        'name': 'FileSteward Development',
        'project': 'FileSteward',
        'goal':
            'Inspect a selected folder and build a deterministic recursive manifest.',
        'phase': 'Development',
        'started_at': _startedAt.toIso8601String(),
        'updated_at': now.toIso8601String(),
        'milestone': 'Manifest workflow connected to AgentBoard',
        'checkpoint_eta': checkpointEta.toIso8601String(),
        'total_agents': 1,
        'active_agents': status == 'working' ? 1 : 0,
        'completed_agents': status == 'completed' ? 1 : 0,
        'blocked_agents': isBlocked ? 1 : 0,
        'needs_approval_agents': status == 'needs_approval' ? 1 : 0,
      },
      'agents': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': _roleId,
          'name': _roleName,
          'display_name': _roleName,
          'role_id': _roleId,
          'role_name': _roleName,
          'role': _roleDescription,
          'runtime_agent_id': _roleId,
          'runtime_agent_nickname': _roleName,
          'runtime_status_source': _runtimeStatusSource,
          'status': status,
          'started_at': _startedAt.toIso8601String(),
          'completed_at': status == 'completed' ? now.toIso8601String() : null,
          'progress_label': progressLabel,
          'started_current_task_at': _startedAt.toIso8601String(),
          'estimated_remaining_minutes': status == 'working' ? 10 : 0,
          'last_update_at': now.toIso8601String(),
          'current_task': <String, dynamic>{
            'title': taskTitle,
            'summary': taskSummary,
            'checkpoint': checkpoint,
            'eta_at': checkpointEta.toIso8601String(),
          },
          'files_touched': filesTouched,
          'commands_run': commandsRun,
          'blocker': <String, dynamic>{
            'is_blocked': isBlocked,
            'summary': isBlocked ? taskSummary : 'No blocker',
            'owner': isBlocked ? 'FileSteward' : null,
            'since': isBlocked ? now.toIso8601String() : null,
            'requires_human': false,
          },
          'handoff': <String, dynamic>{
            'ready': status == 'completed',
            'destination': status == 'completed' ? 'Human' : 'FileSteward',
            'summary': status == 'completed'
                ? 'Manifest is ready for review.'
                : 'No handoff pending.',
            'updated_at': now.toIso8601String(),
          },
        },
      ],
      'runtime_agents': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': _roleId,
          'name': _roleName,
          'display_name': _roleName,
          'role_id': _roleId,
          'role_name': _roleName,
          'role': _roleDescription,
          'runtime_agent_id': _roleId,
          'runtime_agent_nickname': _roleName,
          'runtime_status_source': _runtimeStatusSource,
          'status': status,
          'started_at': _startedAt.toIso8601String(),
          'completed_at': status == 'completed' ? now.toIso8601String() : null,
          'started_current_task_at': _startedAt.toIso8601String(),
          'estimated_remaining_minutes': status == 'working' ? 10 : 0,
          'last_update_at': now.toIso8601String(),
          'progress_label': progressLabel,
          'current_task': <String, dynamic>{
            'title': taskTitle,
            'summary': taskSummary,
            'checkpoint': checkpoint,
            'eta_at': checkpointEta.toIso8601String(),
          },
          'files_touched': filesTouched,
          'commands_run': commandsRun,
          'blocker': <String, dynamic>{
            'is_blocked': isBlocked,
            'summary': isBlocked ? taskSummary : 'No blocker',
            'owner': isBlocked ? _roleName : null,
            'since': isBlocked ? now.toIso8601String() : null,
            'requires_human': false,
          },
          'handoff': <String, dynamic>{
            'ready': status == 'completed',
            'destination': status == 'completed' ? 'Human' : _roleName,
            'summary': status == 'completed'
                ? 'Manifest is ready for review.'
                : 'No handoff pending.',
            'updated_at': now.toIso8601String(),
          },
        },
      ],
      'context': <String, dynamic>{'selected_folder_path': selectedFolderPath},
    };

    final file = File('${directory.path}/current_run.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  Future<void> appendEvent({
    required String status,
    required String type,
    required String message,
    List<String> files = const <String>[],
    List<String> commands = const <String>[],
  }) async {
    final directory = await _resolveStatusDirectory();
    await directory.create(recursive: true);

    final event = <String, dynamic>{
      'id': 'filesteward-${DateTime.now().microsecondsSinceEpoch}',
      'agent_id': _roleId,
      'role_id': _roleId,
      'runtime_agent_id': _roleId,
      'runtime_agent_nickname': _roleName,
      'status_source': _runtimeStatusSource,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': type,
      'message': message,
      'status': status,
      'files': files,
      'commands': commands,
    };

    final file = File('${directory.path}/work_log.jsonl');
    await file.writeAsString('${jsonEncode(event)}\n', mode: FileMode.append);
  }

  Future<List<AgentBoardCommand>> readPendingCommands({
    required String agentId,
  }) async {
    final directory = await _resolveStatusDirectory();
    final commandsFile = File('${directory.path}/commands.jsonl');
    if (!await commandsFile.exists()) {
      return <AgentBoardCommand>[];
    }

    final receiptsFile = File('${directory.path}/command_receipts.jsonl');
    final processedIds = <String>{};
    if (await receiptsFile.exists()) {
      final lines = const LineSplitter()
          .convert(await receiptsFile.readAsString())
          .where((line) => line.trim().isNotEmpty);
      for (final line in lines) {
        final decoded = jsonDecode(line) as Map<String, dynamic>;
        processedIds.add(decoded['command_id'] as String);
      }
    }

    final commands =
        const LineSplitter()
            .convert(await commandsFile.readAsString())
            .where((line) => line.trim().isNotEmpty)
            .map(
              (line) => AgentBoardCommand.fromJson(
                jsonDecode(line) as Map<String, dynamic>,
              ),
            )
            .where(
              (command) =>
                  command.agentId == agentId &&
                  !processedIds.contains(command.id),
            )
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return commands;
  }

  Future<void> appendReceipt({
    required String commandId,
    required String outcome,
    required String message,
  }) async {
    final directory = await _resolveStatusDirectory();
    await directory.create(recursive: true);

    final payload = <String, dynamic>{
      'command_id': commandId,
      'outcome': outcome,
      'message': message,
      'processed_at': DateTime.now().toUtc().toIso8601String(),
    };

    final file = File('${directory.path}/command_receipts.jsonl');
    await file.writeAsString('${jsonEncode(payload)}\n', mode: FileMode.append);
  }

  Future<Directory> _resolveStatusDirectory() async {
    final resolved = directoryResolver?.call();
    if (resolved != null) {
      return resolved;
    }

    final override = Platform.environment['FILESTEWARD_AGENT_BOARD_DIR'];
    if (override != null && override.isNotEmpty) {
      return Directory(override);
    }

    final pwd = Platform.environment['PWD'];
    if (pwd != null && pwd.isNotEmpty) {
      return Directory('$pwd/agent_board_status');
    }

    return Directory('${Directory.current.path}/agent_board_status');
  }
}

final DateTime _startedAt = DateTime.now().toUtc();

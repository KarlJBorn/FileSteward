import 'dart:io';
import 'dart:convert';

import 'package:filesteward/agent_board_status_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads only pending commands for the matching agent', () async {
    final tempDir = await Directory.systemTemp.createTemp('agent_board_status');
    final commands = File('${tempDir.path}/commands.jsonl');
    final receipts = File('${tempDir.path}/command_receipts.jsonl');

    await commands.writeAsString(
      '{"id":"cmd-1","agent_id":"filesteward","command":"approve","created_at":"2026-03-23T20:00:00Z"}\n'
      '{"id":"cmd-2","agent_id":"other","command":"retry","created_at":"2026-03-23T20:01:00Z"}\n'
      '{"id":"cmd-3","agent_id":"filesteward","command":"request_checkpoint","created_at":"2026-03-23T20:02:00Z"}\n',
    );
    await receipts.writeAsString(
      '{"command_id":"cmd-1","outcome":"processed","message":"done","processed_at":"2026-03-23T20:03:00Z"}\n',
    );

    final writer = AgentBoardStatusWriter(directoryResolver: () => tempDir);
    try {
      final pending = await writer.readPendingCommands(agentId: 'filesteward');
      expect(pending.map((command) => command.id), <String>['cmd-3']);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test('writes schema 1.1 status with runtime agents', () async {
    final tempDir = await Directory.systemTemp.createTemp('agent_board_status');
    final writer = AgentBoardStatusWriter(directoryResolver: () => tempDir);

    try {
      await writer.writeStatus(
        status: 'working',
        progressLabel: 'Preparing runtime-aware status.',
        taskTitle: 'Write status',
        taskSummary: 'Emit current FileSteward status for AgentBoard.',
        checkpoint: 'Next update',
        isBlocked: false,
        filesTouched: <String>['lib/agent_board_status_writer.dart'],
        commandsRun: <String>['flutter test'],
      );

      final currentRun = File('${tempDir.path}/current_run.json');
      final decoded =
          jsonDecode(await currentRun.readAsString()) as Map<String, dynamic>;

      expect(decoded['schema_version'], '1.1');

      final runtimeAgents =
          decoded['runtime_agents'] as List<dynamic>? ?? <dynamic>[];
      expect(runtimeAgents, isNotEmpty);

      final firstAgent = runtimeAgents.first as Map<String, dynamic>;
      expect(firstAgent['role_id'], 'filesteward');
      expect(firstAgent['runtime_agent_id'], 'filesteward');
      expect(firstAgent['runtime_agent_nickname'], 'FileSteward');
      expect(firstAgent['runtime_status_source'], 'filesteward_app');
      expect(firstAgent['status'], 'working');
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}

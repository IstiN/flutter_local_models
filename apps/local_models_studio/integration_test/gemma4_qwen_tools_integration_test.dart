import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:local_models_flutter/local_models_flutter.dart';
import 'package:path/path.dart' as p;

const _gemmaId = 'gemma4-e2b-it-4bit';
const _qwenId = 'qwen3-4b-instruct-2507-4bit';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Gemma4 tool-calling smoke', (tester) async {
    final model = await _resolveInstalledModel(
      modelId: _gemmaId,
      envVar: 'FLM_GEMMA4_TOOLS_MODEL_DIR',
    );
    if (model == null) {
      return;
    }
    await _runToolCallingSmoke(
      model: model,
      marker: 'gemma-tool-ok',
    );
  });

  testWidgets('Qwen tool-calling smoke', (tester) async {
    final model = await _resolveInstalledModel(
      modelId: _qwenId,
      envVar: 'FLM_QWEN_TOOLS_MODEL_DIR',
    );
    if (model == null) {
      return;
    }
    await _runToolCallingSmoke(
      model: model,
      marker: 'qwen-tool-ok',
    );
  });
}

Future<void> _runToolCallingSmoke({
  required InstalledModel model,
  required String marker,
  Duration timeout = const Duration(seconds: 90),
}) async {
  final tools = <LocalTool>[
    LocalTool.function(
      name: 'get_current_time',
      description: 'Return current UTC time for integration test.',
      parametersJsonSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
      },
    ),
  ];
  final registry = LmToolRegistry()
    ..registerSync(
      'get_current_time',
      (_) => '{"ok":true,"marker":"$marker","currentTimeUtc":"2026-01-01T00:00:00Z"}',
    );

  final runner = LocalChatRunner();
  var onTextCalls = 0;
  final reply = await runner
      .chatStream(
        model: model,
        messages: const <LocalChatMessage>[
          LocalChatMessage.user(
            'Call tool get_current_time exactly once. '
            'Return only the tool result JSON.',
          ),
        ],
        params: LocalChatParams(
          maxTokens: 96,
          temperature: 0.0,
          tools: tools,
        ),
        toolRegistry: registry,
        onText: (_) => onTextCalls++,
      )
      .timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'tool-calling smoke timed out after ${timeout.inSeconds}s for ${model.manifest.id}',
        ),
      );

  expect(onTextCalls, greaterThan(0));
  expect(reply.trim(), isNotEmpty);
  expect(reply, contains(marker));
  expect(reply, isNot(contains('<|tool_call')));
  expect(reply, isNot(contains('<tool_call')));
}

Future<InstalledModel?> _resolveInstalledModel({
  required String modelId,
  required String envVar,
}) async {
  if (!Platform.isMacOS) {
    markTestSkipped('requires macOS + native MLX bridge');
    return null;
  }

  final envPath = Platform.environment[envVar]?.trim();
  final defaultPath = p.join(
    StudioPaths.forCurrentUser().modelsDirectory.path,
    modelId,
  );
  final dir = Directory(
    (envPath != null && envPath.isNotEmpty) ? envPath : defaultPath,
  );
  if (!dir.existsSync()) {
    markTestSkipped(
      'No model at ${dir.path}. Install $modelId or set $envVar',
    );
    return null;
  }

  final catalogJson = await rootBundle.loadString('assets/catalog.json');
  final registry = ModelRegistry.fromCatalogJson(catalogJson);
  final manifest = registry.byId(modelId);
  return InstalledModel(
    manifest: manifest,
    directory: dir,
    sourceLabel: 'integration_test',
    installedAt: DateTime.now(),
    sizeBytes: 0,
  );
}

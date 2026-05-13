import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:local_models_flutter/local_models_flutter.dart';

/// Runs a minimal tool-calling chat against an installed LM when
/// `FLM_TOOLS_TEST_MODEL_PATH` points at a local MLX directory (Gemma / Qwen / etc.).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native chat + tools (optional env model path)', (tester) async {
    final modelPath = Platform.environment['FLM_TOOLS_TEST_MODEL_PATH']?.trim();
    if (modelPath == null || modelPath.isEmpty) {
      return;
    }
    final dir = Directory(modelPath);
    expect(dir.existsSync(), isTrue, reason: 'model dir must exist');

    final manifest = LocalModelManifest(
      id: Platform.environment['FLM_TOOLS_TEST_MODEL_ID']?.trim() ?? 'integration-tool-model',
      displayName: 'Tools integration',
      description: 'env-driven',
      runtimeAdapter: RuntimeAdapter.mlxLm,
      tasks: const [ModelTask.chat],
      source: const ModelSource(
        provider: 'huggingface',
        repo: 'local/env',
        revision: 'main',
        license: 'mit',
      ),
      packaging: PackagingSpec(
        releaseTag: 't',
        archiveName: 't.tar',
        chunkSizeBytes: 1000,
        assetPrefix: 't',
      ),
      requirements: SystemRequirements(
        platform: 'macos-apple-silicon',
        minMemoryGb: 4,
        recommendedMemoryGb: 8,
        notes: [],
      ),
      capabilities: const CapabilitySpec(
        audioInput: false,
        audioOutput: false,
        toolCalling: true,
      ),
    );

    final model = InstalledModel(
      manifest: manifest,
      directory: dir,
      sourceLabel: 'env',
      installedAt: DateTime.now(),
      sizeBytes: 1,
    );

    final tools = [
      LocalTool.function(
        name: 'return_magic_token',
        description: 'Returns a known string for assertions.',
        parametersJsonSchema: const {
          'type': 'object',
          'properties': <String, Object?>{},
        },
      ),
    ];

    final registry = LmToolRegistry()
      ..registerSync('return_magic_token', (_) => 'magic-42');

    final runner = LocalChatRunner();
    final reply = await runner.chatStream(
      model: model,
      messages: const [
        LocalChatMessage.user(
          'Call the tool return_magic_token once to answer. '
          'Reply only with the tool result.',
        ),
      ],
      params: LocalChatParams(maxTokens: 128, tools: tools),
      toolRegistry: registry,
      onText: (_) {},
    );

    expect(reply.toLowerCase(), contains('magic-42'));
  });
}

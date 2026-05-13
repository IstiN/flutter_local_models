import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_models_core/local_models_core.dart';
import 'package:local_models_flutter/local_models_flutter.dart';

const _lmManifest = LocalModelManifest(
  id: 'test-lm-tool',
  displayName: 'Test LM',
  description: 'fixture',
  runtimeAdapter: RuntimeAdapter.mlxLm,
  tasks: [ModelTask.chat],
  source: ModelSource(
    provider: 'huggingface',
    repo: 'mlx-community/test',
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
  capabilities: CapabilitySpec(
    audioInput: false,
    audioOutput: false,
    toolCalling: true,
  ),
);

void main() {
  test('LmToolRegistry invokes registered handler', () async {
    final reg = LmToolRegistry();
    reg.registerSync('add', (args) {
      final a = (args['a'] as num?)?.toInt() ?? 0;
      final b = (args['b'] as num?)?.toInt() ?? 0;
      return '${a + b}';
    });
    expect(await reg.invoke('add', {'a': 2, 'b': 3}), '5');
  });

  test('LocalChatRunner rejects tools without registry', () async {
    final tmp = Directory.systemTemp.createTempSync('flm-tool-chat-test');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final runner = LocalChatRunner(engine: _ThrowingLmEngine());
    final model = InstalledModel(
      manifest: _lmManifest,
      directory: tmp,
      sourceLabel: 't',
      installedAt: DateTime.now(),
      sizeBytes: 1,
    );
    expect(
      () => runner.chatStream(
        model: model,
        messages: const [LocalChatMessage.user('hi')],
        onText: (_) {},
        params: LocalChatParams(
          tools: [
            LocalTool.function(
              name: 'x',
              description: 'd',
              parametersJsonSchema: const {
                'type': 'object',
                'properties': <String, Object?>{},
              },
            ),
          ],
        ),
      ),
      throwsStateError,
    );
  });
}

final class _ThrowingLmEngine implements LmEngine {
  @override
  Future<String> complete(LmCompletionRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<String> completeStreaming(
    LmCompletionRequest request,
    void Function(String chunk) onChunk,
  ) {
    throw UnimplementedError();
  }
}

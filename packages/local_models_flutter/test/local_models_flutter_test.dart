import 'package:flutter_test/flutter_test.dart';
import 'package:local_models_core/local_models_core.dart';
import 'package:local_models_flutter/local_models_flutter.dart';
import 'package:local_models_flutter/local_models_flutter_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockLocalModelsFlutterPlatform
    with MockPlatformInterfaceMixin
    implements LocalModelsFlutterPlatform {
  @override
  Future<NativeRuntimeSummary> getRuntimeSummary() async {
    return const NativeRuntimeSummary(
      bridgeVersion: 'test-bridge',
      platform: 'macOS test',
      metalAvailable: true,
      mlxFocused: true,
      ffiEnabled: true,
    );
  }
}

class FakeChatRuntime implements LocalChatRuntime {
  @override
  Future<List<LocalModelManifest>> getModels() async {
    return const [
      LocalModelManifest(
        id: 'fake-model',
        displayName: 'Fake Model',
        description: 'Test model',
        runtimeAdapter: RuntimeAdapter.mlxLm,
        tasks: [ModelTask.chat],
        source: ModelSource(
          provider: 'test',
          repo: 'test/fake-model',
          revision: 'main',
          license: 'mit',
        ),
        packaging: PackagingSpec(
          releaseTag: 'model-fake-model',
          archiveName: 'fake-model.tar',
          chunkSizeBytes: 1,
          assetPrefix: 'fake-model',
        ),
        requirements: SystemRequirements(
          platform: 'macos-apple-silicon',
          minMemoryGb: 1,
          recommendedMemoryGb: 1,
          notes: [],
        ),
        capabilities: CapabilitySpec(
          audioInput: false,
          audioOutput: false,
          toolCalling: false,
        ),
      ),
    ];
  }

  @override
  Stream<LocalChatDelta> chatStream({
    required List<LocalChatMessage> messages,
    LocalChatParams params = const LocalChatParams(),
  }) async* {
    expect(messages.single.role, LocalChatRole.user);
    expect(params.modelId, 'fake-model');
    expect(params.maxTokens, 12);
    yield const LocalChatDelta(content: 'hel');
    yield const LocalChatDelta(content: 'lo', done: true);
  }
}

void main() {
  test(
    'getRuntimeSummary delegates to the active platform implementation',
    () async {
      final plugin = LocalModelsFlutter();
      final fakePlatform = MockLocalModelsFlutterPlatform();
      LocalModelsFlutterPlatform.instance = fakePlatform;

      final summary = await plugin.getRuntimeSummary();

      expect(summary.bridgeVersion, 'test-bridge');
      expect(summary.metalAvailable, isTrue);
    },
  );

  test('chat builds a response from the configured stream runtime', () async {
    final plugin = LocalModelsFlutter(chatRuntime: FakeChatRuntime());
    final models = await plugin.getModels();
    final response = await plugin.chat(
      messages: const [LocalChatMessage.user('hi')],
      params: const LocalChatParams(modelId: 'fake-model', maxTokens: 12),
    );

    expect(models.single.id, 'fake-model');
    expect(response.message.role, LocalChatRole.assistant);
    expect(response.message.content, 'hello');
  });
}

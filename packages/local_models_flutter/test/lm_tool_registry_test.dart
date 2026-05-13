import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

  test(
    'LocalChatRunner invokes registry for embedded Gemma tool blocks',
    () async {
      final tmp = Directory.systemTemp.createTempSync(
        'flm-gemma-tool-chat-test',
      );
      addTearDown(() => tmp.deleteSync(recursive: true));

      final runner = LocalChatRunner(engine: _RawToolCallLmEngine());
      final model = InstalledModel(
        manifest: _lmManifest,
        directory: tmp,
        sourceLabel: 't',
        installedAt: DateTime.now(),
        sizeBytes: 1,
      );
      final registry = LmToolRegistry()
        ..registerSync('get_current_time', (_) => '{"currentTimeUtc":"now"}');

      final response = await runner.chatStream(
        model: model,
        messages: const [LocalChatMessage.user('what time is it?')],
        onText: (_) {},
        params: LocalChatParams(
          tools: [
            LocalTool.function(
              name: 'get_current_time',
              description: 'time',
              parametersJsonSchema: const {
                'type': 'object',
                'properties': <String, Object?>{},
              },
            ),
          ],
        ),
        toolRegistry: registry,
      );

      expect(response, 'The current time is now.');
      expect(response, isNot(contains('<|tool_call|>')));
      expect(response, isNot(contains('[get_current_time]')));
    },
  );

  test(
    'LocalChatRunner answers Gemma get_tools without registry handler',
    () async {
      final tmp = Directory.systemTemp.createTempSync(
        'flm-gemma-get-tools-test',
      );
      addTearDown(() => tmp.deleteSync(recursive: true));

      final runner = LocalChatRunner(engine: _GetToolsLmEngine());
      final model = InstalledModel(
        manifest: _lmManifest,
        directory: tmp,
        sourceLabel: 't',
        installedAt: DateTime.now(),
        sizeBytes: 1,
      );
      final registry = LmToolRegistry();

      final response = await runner.chatStream(
        model: model,
        messages: const [LocalChatMessage.user('which tools do you have?')],
        onText: (_) {},
        params: LocalChatParams(
          tools: [
            LocalTool.function(
              name: 'get_current_time',
              description: 'time',
              parametersJsonSchema: const {
                'type': 'object',
                'properties': <String, Object?>{},
              },
            ),
          ],
        ),
        toolRegistry: registry,
      );

      expect(response, 'You can use get_current_time.');
      expect(response, isNot(contains('<|tool_call|>')));
      expect(response, isNot(contains('[get_tools]')));
    },
  );

  test(
    'LocalChatRunner feeds multiple Gemma tool results back to model',
    () async {
      final tmp = Directory.systemTemp.createTempSync(
        'flm-gemma-multi-tool-test',
      );
      addTearDown(() => tmp.deleteSync(recursive: true));

      final runner = LocalChatRunner(engine: _MultiToolLmEngine());
      final model = InstalledModel(
        manifest: _lmManifest,
        directory: tmp,
        sourceLabel: 't',
        installedAt: DateTime.now(),
        sizeBytes: 1,
      );
      final registry = LmToolRegistry()
        ..registerSync('get_current_time', (_) => '18:52 UTC')
        ..registerSync('echo_message', (args) => 'echo:${args['message']}');

      final response = await runner.chatStream(
        model: model,
        messages: const [LocalChatMessage.user('use two tools')],
        onText: (_) {},
        params: LocalChatParams(
          tools: [
            LocalTool.function(
              name: 'get_current_time',
              description: 'time',
              parametersJsonSchema: const {
                'type': 'object',
                'properties': <String, Object?>{},
              },
            ),
            LocalTool.function(
              name: 'echo_message',
              description: 'echo',
              parametersJsonSchema: const {
                'type': 'object',
                'properties': <String, Object?>{
                  'message': <String, Object?>{'type': 'string'},
                },
              },
            ),
          ],
        ),
        toolRegistry: registry,
      );

      expect(response, 'I used both tools: 18:52 UTC and echo:hello.');
      expect(response, isNot(contains('<|tool_call|>')));
      expect(response, isNot(contains('[echo_message]')));
    },
  );
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

final class _RawToolCallLmEngine implements LmEngine {
  @override
  Future<String> complete(LmCompletionRequest request) async {
    expect(request.tools, isEmpty);
    expect(request.onToolCall, isNull);
    expect(request.prompt, contains('[get_current_time]'));
    expect(request.prompt, contains('currentTimeUtc'));
    return 'The current time is now.';
  }

  @override
  Future<String> completeStreaming(
    LmCompletionRequest request,
    void Function(String chunk) onChunk,
  ) async {
    const raw = r'<|tool_call|>call:get_current_time{}<tool_call|>';
    onChunk(raw);
    return raw;
  }
}

final class _GetToolsLmEngine implements LmEngine {
  @override
  Future<String> complete(LmCompletionRequest request) async {
    expect(request.tools, isEmpty);
    expect(request.onToolCall, isNull);
    expect(request.prompt, contains('[get_tools]'));
    expect(request.prompt, contains('get_current_time'));
    return 'You can use get_current_time.';
  }

  @override
  Future<String> completeStreaming(
    LmCompletionRequest request,
    void Function(String chunk) onChunk,
  ) async {
    const raw = r'<|tool_call|>call:get_tools{}<tool_call|>';
    onChunk(raw);
    return raw;
  }
}

final class _MultiToolLmEngine implements LmEngine {
  @override
  Future<String> complete(LmCompletionRequest request) async {
    expect(request.tools, isEmpty);
    expect(request.onToolCall, isNull);
    expect(request.prompt, contains('[get_current_time]'));
    expect(request.prompt, contains('18:52 UTC'));
    expect(request.prompt, contains('[echo_message]'));
    expect(request.prompt, contains('echo:hello'));
    return 'I used both tools: 18:52 UTC and echo:hello.';
  }

  @override
  Future<String> completeStreaming(
    LmCompletionRequest request,
    void Function(String chunk) onChunk,
  ) async {
    const raw =
        r'<|tool_call|>call:get_current_time{}<tool_call|>'
        r'<|tool_call|>call:echo_message{message:<|"|>hello<|"|>}<tool_call|>';
    onChunk(raw);
    return raw;
  }
}

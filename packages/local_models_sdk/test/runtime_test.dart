import 'dart:convert';
import 'dart:io';

import 'package:local_models_sdk/local_models_sdk.dart';
import 'package:test/test.dart';

const _manifest = LocalModelManifest(
  id: 'test-runtime-model',
  displayName: 'Test Runtime Model',
  description: 'fixture',
  runtimeAdapter: RuntimeAdapter.mlxLm,
  tasks: [ModelTask.chat],
  source: ModelSource(
    provider: 'huggingface',
    repo: 'example/test-runtime-model',
    revision: 'main',
    license: 'mit',
  ),
  packaging: PackagingSpec(
    releaseTag: 'v1',
    archiveName: 'test.tar',
    chunkSizeBytes: 1,
    assetPrefix: 'test',
  ),
  requirements: SystemRequirements(
    platform: 'macos-apple-silicon',
    minMemoryGb: 1,
    recommendedMemoryGb: 2,
    notes: [],
  ),
  capabilities: CapabilitySpec(
    audioInput: false,
    audioOutput: false,
    toolCalling: true,
  ),
);

void main() {
  test('LocalChatRunner answers get_tools without registry handler', () async {
    final tmp = await Directory.systemTemp.createTemp('flm-sdk-runtime-test');
    addTearDown(() async {
      if (tmp.existsSync()) {
        await tmp.delete(recursive: true);
      }
    });
    final runner = LocalChatRunner(engine: _GetToolsEngine());
    final model = InstalledModel(
      manifest: _manifest,
      directory: tmp,
      sourceLabel: 'test',
      installedAt: DateTime.utc(2026, 1, 1),
      sizeBytes: 1,
    );
    final registry = LmToolRegistry();

    final text = await runner.chatStream(
      model: model,
      messages: const [
        LocalChatMessage(
          role: LocalChatRole.user,
          content: 'which tools do you have?',
        ),
      ],
      onText: (_) {},
      params: const LocalChatParams(
        tools: [
          LocalTool.function(
            name: 'get_current_time',
            description: 'Return current time.',
            parametersJsonSchema: <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{},
            },
          ),
        ],
      ),
      toolRegistry: registry,
    );

    final decoded = jsonDecode(text) as Map<String, Object?>;
    expect(decoded['tools'], isNotEmpty);
    expect(text, contains('get_current_time'));
  });

  test(
    'LocalChatRunner handles one then two embedded Gemma tool calls',
    () async {
      final tmp = await Directory.systemTemp.createTemp(
        'flm-sdk-gemma-loop-test',
      );
      addTearDown(() async {
        if (tmp.existsSync()) {
          await tmp.delete(recursive: true);
        }
      });
      final runner = LocalChatRunner(engine: _GemmaToolLoopEngine());
      final model = InstalledModel(
        manifest: _manifest,
        directory: tmp,
        sourceLabel: 'test',
        installedAt: DateTime.utc(2026, 1, 1),
        sizeBytes: 1,
      );
      final registry = LmToolRegistry()
        ..registerSync('get_current_time', (_) => '2026-05-13T19:03:00Z')
        ..registerSync('echo_message', (args) => 'echo:${args['message']}');
      const params = LocalChatParams(
        maxTokens: 128,
        temperature: 0,
        tools: [
          LocalTool.function(
            name: 'get_current_time',
            description: 'Return current time.',
            parametersJsonSchema: <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{},
            },
          ),
          LocalTool.function(
            name: 'echo_message',
            description: 'Echo a message.',
            parametersJsonSchema: <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'message': <String, Object?>{'type': 'string'},
              },
              'required': <String>['message'],
            },
          ),
        ],
      );

      final firstReply = await runner.chatStream(
        model: model,
        messages: const [
          LocalChatMessage(
            role: LocalChatRole.user,
            content: 'Call exactly one tool and then answer.',
          ),
        ],
        onText: (_) {},
        params: params,
        toolRegistry: registry,
      );
      expect(firstReply, 'Single tool answer: 2026-05-13T19:03:00Z.');
      expect(firstReply, isNot(contains('<|tool_call')));
      expect(firstReply, isNot(contains('[get_current_time]')));

      final secondReply = await runner.chatStream(
        model: model,
        messages: [
          const LocalChatMessage(
            role: LocalChatRole.user,
            content: 'Call exactly one tool and then answer.',
          ),
          LocalChatMessage(role: LocalChatRole.assistant, content: firstReply),
          const LocalChatMessage(
            role: LocalChatRole.user,
            content: 'Now call two tools and then answer.',
          ),
        ],
        onText: (_) {},
        params: params,
        toolRegistry: registry,
      );
      expect(
        secondReply,
        'Two tool answer: 2026-05-13T19:03:00Z and echo:hello.',
      );
      expect(secondReply, isNot(contains('<|tool_call')));
      expect(secondReply, isNot(contains('[get_current_time]')));
      expect(secondReply, isNot(contains('[echo_message]')));
    },
  );
}

final class _GetToolsEngine implements LmEngine {
  @override
  Future<String> complete(LmCompletionRequest request) async {
    return request.onToolCall!('get_tools', const <String, Object?>{});
  }

  @override
  Future<String> completeStreaming(
    LmCompletionRequest request,
    void Function(String chunk) onChunk,
  ) async {
    final text = await complete(request);
    onChunk(text);
    return text;
  }
}

final class _GemmaToolLoopEngine implements LmEngine {
  @override
  Future<String> complete(LmCompletionRequest request) async {
    expect(request.tools, isEmpty);
    expect(request.onToolCall, isNull);
    if (request.prompt.contains('[echo_message]')) {
      expect(request.prompt, contains('[get_current_time]'));
      expect(request.prompt, contains('2026-05-13T19:03:00Z'));
      expect(request.prompt, contains('echo:hello'));
      return 'Two tool answer: 2026-05-13T19:03:00Z and echo:hello.';
    }
    expect(request.prompt, contains('[get_current_time]'));
    expect(request.prompt, contains('2026-05-13T19:03:00Z'));
    return 'Single tool answer: 2026-05-13T19:03:00Z.';
  }

  @override
  Future<String> completeStreaming(
    LmCompletionRequest request,
    void Function(String chunk) onChunk,
  ) async {
    expect(request.tools, isNotEmpty);
    expect(request.onToolCall, isNotNull);
    final raw = request.prompt.contains('two tools')
        ? r'<|tool_call|>call:get_current_time{}<tool_call|>'
              r'<|tool_call|>call:echo_message{message:<|"|>hello<|"|>}<tool_call|>'
        : r'<|tool_call|>call:get_current_time{}<tool_call|>';
    onChunk(raw);
    return raw;
  }
}

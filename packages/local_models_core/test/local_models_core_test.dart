import 'dart:io';

import 'package:local_models_core/local_models_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _sampleManifest = '''
id: qwen3-asr-0.6b-4bit
display_name: Qwen3 ASR 0.6B 4bit
description: Fast multilingual speech-to-text model for local MLX workflows.
runtime_adapter: mlx_audio
tasks:
  - speech_to_text
source:
  provider: huggingface
  repo: mlx-community/Qwen3-ASR-0.6B-4bit
  revision: main
  license: apache-2.0
packaging:
  release_tag: model-qwen3-asr-0.6b-4bit
  archive_name: qwen3-asr-0.6b-4bit.tar
  chunk_size_bytes: 1900000000
  asset_prefix: qwen3-asr-0.6b-4bit
requirements:
  platform: macos-apple-silicon
  min_memory_gb: 8
  recommended_memory_gb: 16
  notes:
    - Optimized for local speech recognition
capabilities:
  audio_input: true
  audio_output: false
  tool_calling: false
model_card:
  summary: Small ASR model for app testing.
  use_cases:
    - Dictation
    - Voice assistant input
  limitations:
    - Noisy audio can reduce accuracy
  languages:
    - ru
    - en
  tags:
    - asr
  links:
    huggingface: https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-4bit
runtime_config:
  default_parameters:
    language: auto
  voices:
    - id: default
      display_name: Default voice
      locale: multilingual
  output:
    format: text
''';

Directory _findRepoRoot() {
  var current = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory(p.join(current.path, 'registry', 'models')).existsSync()) {
      return current;
    }
    current = current.parent;
  }
  throw StateError('Could not locate repo root from ${Directory.current.path}');
}

void main() {
  test('parses yaml manifests', () {
    final manifest = LocalModelManifest.fromYaml(_sampleManifest);
    expect(manifest.id, 'qwen3-asr-0.6b-4bit');
    expect(manifest.runtimeAdapter, RuntimeAdapter.mlxAudio);
    expect(manifest.tasks, [ModelTask.speechToText]);
    expect(manifest.capabilities.audioInput, isTrue);
    expect(manifest.modelCard.summary, 'Small ASR model for app testing.');
    expect(manifest.modelCard.useCases, contains('Dictation'));
    expect(manifest.modelCard.languages, contains('ru'));
    expect(manifest.runtimeConfig.defaultParameters['language'], 'auto');
    expect(manifest.runtimeConfig.voices.single.displayName, 'Default voice');
    expect(manifest.runtimeConfig.output['format'], 'text');
    expect(manifest.packaging.releaseTag, 'model-qwen3-asr-0.6b-4bit');
  });

  test('parses mflux image generation manifests', () {
    final manifest = LocalModelManifest.fromYaml(
      _sampleManifest
          .replaceAll('runtime_adapter: mlx_audio', 'runtime_adapter: mflux')
          .replaceAll('  - speech_to_text', '  - image_generation'),
    );

    expect(manifest.runtimeAdapter, RuntimeAdapter.mflux);
    expect(manifest.tasks, [ModelTask.imageGeneration]);
    expect(modelTaskToString(manifest.tasks.single), 'image_generation');
  });

  test('loads and sorts a registry directory', () async {
    final temp = await Directory.systemTemp.createTemp('local-models-core-');
    addTearDown(() => temp.delete(recursive: true));

    final gemma = File(p.join(temp.path, 'gemma.yaml'));
    await gemma.writeAsString(
      _sampleManifest
          .replaceAll('Qwen3 ASR 0.6B 4bit', 'Gemma 4 E4B IT 4bit')
          .replaceAll('qwen3-asr-0.6b-4bit', 'gemma4-e4b-it-4bit'),
    );
    final qwen = File(p.join(temp.path, 'qwen.yaml'));
    await qwen.writeAsString(_sampleManifest);

    final registry = await ModelRegistry.loadDirectory(temp.path);
    expect(registry.manifests.length, 2);
    expect(registry.manifests.first.displayName, 'Gemma 4 E4B IT 4bit');
    expect(
      registry.byId('qwen3-asr-0.6b-4bit').source.repo,
      'mlx-community/Qwen3-ASR-0.6B-4bit',
    );
  });

  test('loads repo registry manifests with rich runtime metadata', () async {
    final repoRoot = _findRepoRoot();
    final registry = await ModelRegistry.loadDirectory(
      p.join(repoRoot.path, 'registry', 'models'),
    );

    expect(registry.manifests.length, greaterThanOrEqualTo(30));

    final qwen = registry.byId('qwen3-4b-instruct-2507-4bit');
    expect(qwen.runtimeAdapter, RuntimeAdapter.mlxLm);
    expect(qwen.runtimeConfig.defaultParameters['top_k'], 20);
    expect(qwen.runtimeConfig.extra['context_length'], 262144);
    expect(qwen.modelCard.tags, contains('qwen3'));

    final speechToSpeech = registry.byId('lfm2.5-audio-1.5b-8bit');
    expect(speechToSpeech.tasks, contains(ModelTask.audioInput));
    expect(speechToSpeech.tasks, contains(ModelTask.audioOutput));
    expect(
      speechToSpeech.runtimeConfig.defaultParameters['audio_temperature'],
      0.7,
    );
    expect(
      speechToSpeech.runtimeConfig.output['supports_streaming_chunks'],
      isTrue,
    );

    final voxtral = registry.byId('voxtral-4b-tts-2603-4bit');
    expect(voxtral.runtimeConfig.voices.length, 20);
    expect(
      voxtral.runtimeConfig.parameterSchema['properties'],
      containsPair('voice', isA<Map<Object?, Object?>>()),
    );

    final whisper = registry.byId('whisper-small-asr-4bit');
    expect(whisper.runtimeConfig.defaultParameters['language'], 'auto');
    expect(whisper.runtimeConfig.extra['model_type'], 'whisper');
    expect(whisper.modelCard.languages, contains('Russian'));

    final toolModel = registry.byId('falcon-h1-tiny-tool-calling-90m-4bit');
    expect(toolModel.capabilities.toolCalling, isTrue);
    expect(toolModel.runtimeConfig.extra['context_length'], 262144);

    final visionModel = registry.byId('qwen3.5-0.8b-vlm-4bit');
    expect(visionModel.tasks, contains(ModelTask.vision));
    expect(
      visionModel.runtimeConfig.extra['hf_size_bytes'],
      lessThan(1000000000),
    );
  });

  test('creates a predictable release bundle plan', () {
    final manifest = LocalModelManifest.fromYaml(_sampleManifest);
    final plan = ReleaseBundlePlan.fromManifest(manifest, sampleChunkCount: 2);

    expect(plan.releaseTag, 'model-qwen3-asr-0.6b-4bit');
    expect(plan.sampleChunks.first.fileName, 'qwen3-asr-0.6b-4bit.part-000');
    expect(plan.sampleChunks.last.fileName, 'qwen3-asr-0.6b-4bit.part-001');
  });

  test('serializes chat messages with attachments and params', () {
    final attachment = LocalMessageAttachment.file(
      type: LocalAttachmentType.audio,
      path: '/tmp/input.wav',
      mimeType: 'audio/wav',
    );
    final message = LocalChatMessage.user(
      'transcribe this',
      attachments: [attachment],
    );
    final decoded = LocalChatMessage.fromJsonMap(message.toJson());

    expect(decoded.role, LocalChatRole.user);
    expect(decoded.content, 'transcribe this');
    expect(decoded.attachments.single.type, LocalAttachmentType.audio);
    expect(decoded.attachments.single.filePath, '/tmp/input.wav');

    final params = LocalChatParams(
      modelId: 'qwen3-8b-4bit',
      maxTokens: 128,
      temperature: 0.2,
      topP: 0.8,
      stop: ['</tool_call>'],
      extra: {'seed': 7},
    );
    final decodedParams = LocalChatParams.fromJsonMap(params.toJson());
    final openAIParams = params.toOpenAIJson();
    expect(decodedParams.maxTokens, 128);
    expect(openAIParams['model'], 'qwen3-8b-4bit');
    expect(openAIParams['max_tokens'], 128);
    expect(openAIParams['top_p'], 0.8);
    expect(openAIParams['seed'], 7);
  });

  test('serializes tools, tool choices, and tool call messages', () {
    const tool = LocalTool.function(
      name: 'get_weather',
      description: 'Get weather for a city.',
      parametersJsonSchema: {
        'type': 'object',
        'properties': {
          'city': {'type': 'string'},
        },
        'required': ['city'],
      },
    );
    const toolCall = LocalToolCall(
      id: 'call_1',
      name: 'get_weather',
      arguments: {'city': 'Minsk'},
    );
    const params = LocalChatParams(
      tools: [tool],
      toolChoice: LocalToolChoice.named('get_weather'),
    );
    const assistant = LocalChatMessage.assistant('', toolCalls: [toolCall]);
    const result = LocalChatMessage.toolResult(
      toolCallId: 'call_1',
      content: '{"temperature": 21}',
    );

    final decodedParams = LocalChatParams.fromJsonMap(params.toJson());
    final decodedAssistant = LocalChatMessage.fromJsonMap(assistant.toJson());
    final decodedResult = LocalChatMessage.fromJsonMap(result.toJson());

    expect(decodedParams.tools.single.name, 'get_weather');
    expect(decodedParams.toolChoice!.mode, LocalToolChoiceMode.named);
    expect(decodedParams.toolChoice!.name, 'get_weather');
    expect(decodedAssistant.toolCalls.single.arguments['city'], 'Minsk');
    expect(decodedResult.role, LocalChatRole.tool);
    expect(decodedResult.toolCallId, 'call_1');
    expect(tool.toOpenAIJson()['type'], 'function');
    expect(toolCall.toOpenAIJson()['type'], 'function');
  });

  test('serializes chat requests, deltas, and responses', () {
    const request = LocalChatRequest(
      messages: [
        LocalChatMessage.system('You are local.'),
        LocalChatMessage.user('hi'),
      ],
      params: LocalChatParams(modelId: 'falcon-tool', maxTokens: 64),
      metadata: {'traceId': 'trace-1'},
    );
    const delta = LocalChatDelta(
      content: 'hello',
      done: true,
      finishReason: 'stop',
      metadata: {'durationMs': 42},
    );
    const response = LocalChatResponse(
      message: LocalChatMessage.assistant('hello'),
      metadata: {'durationMs': 42},
    );

    final decodedRequest = LocalChatRequest.fromJsonMap(request.toJson());
    final decodedDelta = LocalChatDelta.fromJsonMap(delta.toJson());
    final decodedResponse = LocalChatResponse.fromJsonMap(response.toJson());

    expect(decodedRequest.messages.length, 2);
    expect(decodedRequest.params.modelId, 'falcon-tool');
    expect(decodedRequest.metadata['traceId'], 'trace-1');
    expect(decodedDelta.content, 'hello');
    expect(decodedDelta.done, isTrue);
    expect(decodedDelta.finishReason, 'stop');
    expect(decodedResponse.message.content, 'hello');
    expect(decodedResponse.metadata['durationMs'], 42);
  });
}

import 'dart:async';
import 'dart:io';

import 'package:local_models_core/local_models_core.dart';
import 'package:local_models_sdk/local_models_sdk.dart' as sdk;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _cliSdkToolLoopManifest = LocalModelManifest(
  id: 'cli-sdk-gemma-tool-loop-test',
  displayName: 'CLI SDK Gemma Tool Loop Test',
  description: 'fixture',
  runtimeAdapter: RuntimeAdapter.mlxLm,
  tasks: [ModelTask.chat],
  source: ModelSource(
    provider: 'local',
    repo: 'integration/cli-sdk-gemma-tool-loop',
    revision: 'main',
    license: 'mit',
  ),
  packaging: PackagingSpec(
    releaseTag: 'test',
    archiveName: 'test.tar',
    chunkSizeBytes: 1,
    assetPrefix: 'test',
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
    toolCalling: true,
  ),
);

void main() {
  final registryDir = Directory(
    p.normalize(
      p.join(Directory.current.path, '..', '..', 'registry', 'models'),
    ),
  );

  test(
    'Qwen chat model responds through headless mlx_lm CLI',
    () async {
      final model = await _requireInstalled(registryDir, 'qwen3-8b-4bit');
      await _requireCommand('mlx_lm.generate');

      final result = await _runProcess('mlx_lm.generate', [
        '--model',
        model.directory.path,
        '--prompt',
        'Reply with exactly this token and nothing else: CLI_CHAT_OK',
        '--max-tokens',
        '16',
        '--temp',
        '0',
      ], timeout: const Duration(minutes: 3));

      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, contains('CLI_CHAT_OK'));
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'SDK chat runner wires tool calls to registry handlers headlessly',
    () async {
      final model = await _requireInstalled(registryDir, 'qwen3-8b-4bit');
      final registry = sdk.LmToolRegistry()
        ..registerSync('get_current_time', (_) => '2026-05-13T18:07:00Z');
      final runner = sdk.LocalChatRunner(engine: _ToolCallingEngine());
      final chunks = <String>[];

      final text = await runner.chatStream(
        model: model,
        messages: const [
          LocalChatMessage(
            role: LocalChatRole.user,
            content: 'What time is it?',
          ),
        ],
        onText: chunks.add,
        params: const LocalChatParams(
          tools: [
            LocalTool(
              name: 'get_current_time',
              description: 'Return the current UTC time.',
              parametersJsonSchema: <String, Object?>{'type': 'object'},
            ),
          ],
        ),
        toolRegistry: registry,
      );

      expect(text, 'Tool returned: 2026-05-13T18:07:00Z');
      expect(chunks, ['Tool returned: 2026-05-13T18:07:00Z']);
    },
  );

  test(
    'Qwen chat model emits tool-call text that can invoke SDK registry',
    () async {
      final model = await _requireInstalled(registryDir, 'qwen3-8b-4bit');
      await _requireCommand('mlx_lm.generate');
      final registry = sdk.LmToolRegistry()
        ..registerSync('get_current_time', (_) => '2026-05-13T18:07:00Z');

      final result = await _runProcess('mlx_lm.generate', [
        '--model',
        model.directory.path,
        '--chat-template-config',
        '{"enable_thinking":false}',
        '--prompt',
        'Print exactly this token sequence and no explanation: <|tool_call|>call:get_current_time{}<|tool_call|>',
        '--max-tokens',
        '64',
        '--temp',
        '0',
        '--verbose',
        'false',
      ], timeout: const Duration(minutes: 3));

      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, contains('call:get_current_time'));
      final toolResult = await registry.invoke(
        'get_current_time',
        const <String, Object?>{},
      );
      expect(toolResult, '2026-05-13T18:07:00Z');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test('CLI SDK handles one then two embedded Gemma tool calls', () async {
    final tmp = await Directory.systemTemp.createTemp('flm-cli-gemma-loop-');
    addTearDown(() async {
      if (tmp.existsSync()) {
        await tmp.delete(recursive: true);
      }
    });
    final model = sdk.InstalledModel(
      manifest: _cliSdkToolLoopManifest,
      directory: tmp,
      sourceLabel: 'integration_test',
      installedAt: DateTime.utc(2026, 5, 13),
      sizeBytes: 1,
    );
    final registry = sdk.LmToolRegistry()
      ..registerSync('get_current_time', (_) => '2026-05-13T19:03:00Z')
      ..registerSync('echo_message', (args) => 'echo:${args['message']}');
    final runner = sdk.LocalChatRunner(engine: _GemmaToolLoopEngine());
    const params = LocalChatParams(
      maxTokens: 128,
      temperature: 0,
      tools: [
        LocalTool.function(
          name: 'get_current_time',
          description: 'Return current UTC time.',
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
  });

  test(
    'Qwen image model generates an image through mflux CLI',
    () async {
      final model = await _requireInstalled(
        registryDir,
        'qwen-image-2512-4bit',
      );
      await _requireCommand('mflux-generate-qwen');

      final outDir = await Directory.systemTemp.createTemp('flm-qwen-image-');
      addTearDown(() async {
        if (outDir.existsSync()) {
          await outDir.delete(recursive: true);
        }
      });
      final outPath = p.join(outDir.path, 'qwen-image.png');

      final result = await _runProcess('mflux-generate-qwen', [
        '--model',
        model.directory.path,
        '--prompt',
        'a tiny red square icon on white background',
        '--height',
        '256',
        '--width',
        '256',
        '--steps',
        '1',
        '--seed',
        '7',
        '--output',
        outPath,
      ], timeout: const Duration(minutes: 5));

      expect(result.exitCode, 0, reason: result.stderr);
      final outFile = File(outPath);
      expect(outFile.existsSync(), isTrue);
      expect(await outFile.length(), greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test(
    'Qwen TTS model generates wav through mlx_audio CLI',
    () async {
      final model = await _requireInstalled(
        registryDir,
        'qwen3-tts-12hz-0.6b-base-4bit',
      );
      await _requireCommand('mlx_audio.tts.generate');

      final outDir = await Directory.systemTemp.createTemp('flm-qwen-tts-');
      addTearDown(() async {
        if (outDir.existsSync()) {
          await outDir.delete(recursive: true);
        }
      });

      final result = await _runProcess('mlx_audio.tts.generate', [
        '--model',
        model.directory.path,
        '--text',
        'Hello from CLI runtime test.',
        '--voice',
        'Ryan',
        '--lang_code',
        'english',
        '--output_path',
        outDir.path,
        '--file_prefix',
        'qwen_tts_smoke',
        '--join_audio',
      ], timeout: const Duration(minutes: 5));

      expect(result.exitCode, 0, reason: result.stderr);
      final audio = await _firstFileWithExtensions(outDir, const [
        '.wav',
        '.mp3',
      ]);
      expect(audio, isNotNull);
      expect(await audio!.length(), greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test(
    'Qwen ASR model transcribes generated wav through mlx_audio CLI',
    () async {
      final ttsModel = await _requireInstalled(
        registryDir,
        'qwen3-tts-12hz-0.6b-base-4bit',
      );
      final asrModel = await _requireInstalled(
        registryDir,
        'qwen3-asr-0.6b-4bit',
      );
      await _requireCommand('mlx_audio.tts.generate');
      await _requireCommand('mlx_audio.stt.generate');

      final workDir = await Directory.systemTemp.createTemp('flm-qwen-asr-');
      addTearDown(() async {
        if (workDir.existsSync()) {
          await workDir.delete(recursive: true);
        }
      });
      final audioDir = Directory(p.join(workDir.path, 'audio'))..createSync();
      final transcriptPath = p.join(workDir.path, 'asr_output');

      final phrase = 'orange bicycle';
      final tts = await _runProcess('mlx_audio.tts.generate', [
        '--model',
        ttsModel.directory.path,
        '--text',
        phrase,
        '--voice',
        'Ryan',
        '--lang_code',
        'english',
        '--output_path',
        audioDir.path,
        '--file_prefix',
        'asr_input',
        '--join_audio',
      ], timeout: const Duration(minutes: 5));
      expect(tts.exitCode, 0, reason: tts.stderr);
      final audio = await _firstFileWithExtensions(audioDir, const [
        '.wav',
        '.mp3',
      ]);
      expect(audio, isNotNull);

      final asr = await _runProcess('mlx_audio.stt.generate', [
        '--model',
        asrModel.directory.path,
        '--audio',
        audio!.path,
        '--output-path',
        transcriptPath,
        '--format',
        'txt',
        '--language',
        'en',
      ], timeout: const Duration(minutes: 4));
      expect(asr.exitCode, 0, reason: asr.stderr);
      final transcript = await _resolveSttOutputFile(transcriptPath);
      expect(transcript.existsSync(), isTrue);
      final text = (await transcript.readAsString()).toLowerCase();
      expect(text, anyOf(contains('orange'), contains('bicycle')));
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<sdk.InstalledModel> _requireInstalled(
  Directory registryDir,
  String modelId,
) async {
  final registry = await ModelRegistry.loadDirectory(registryDir.path);
  final models = await sdk.LocalModelStore(
    registry: registry,
  ).listInstalledModels();
  sdk.InstalledModel? model;
  for (final item in models) {
    if (item.manifest.id == modelId) {
      model = item;
      break;
    }
  }
  if (model == null) {
    markTestSkipped('Installed model not found: $modelId');
    throw StateError('skipped');
  }
  return model;
}

Future<void> _requireCommand(String name) async {
  final result = await Process.run('sh', [
    '-lc',
    'command -v ${_shellQuote(name)}',
  ]);
  if (result.exitCode != 0) {
    markTestSkipped('Required command not found on PATH: $name');
  }
}

Future<_ProcessOutput> _runProcess(
  String executable,
  List<String> args, {
  required Duration timeout,
}) async {
  final process = await Process.start(executable, args);
  final stdoutBuffer = StringBuffer();
  final stderrBuffer = StringBuffer();
  final stdoutSub = process.stdout
      .transform(const SystemEncoding().decoder)
      .listen(stdoutBuffer.write);
  final stderrSub = process.stderr
      .transform(const SystemEncoding().decoder)
      .listen(stderrBuffer.write);
  try {
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill(ProcessSignal.sigterm);
        throw TimeoutException(
          '$executable timed out after ${timeout.inSeconds}s',
        );
      },
    );
    return _ProcessOutput(
      exitCode: exitCode,
      stdout: stdoutBuffer.toString(),
      stderr: stderrBuffer.toString(),
    );
  } finally {
    await stdoutSub.cancel();
    await stderrSub.cancel();
  }
}

Future<File?> _firstFileWithExtensions(
  Directory dir,
  List<String> extensions,
) async {
  if (!dir.existsSync()) {
    return null;
  }
  await for (final entity in dir.list(recursive: true)) {
    if (entity is File &&
        extensions.contains(p.extension(entity.path).toLowerCase())) {
      return entity;
    }
  }
  return null;
}

Future<File> _resolveSttOutputFile(String outputPath) async {
  final direct = File(outputPath);
  if (direct.existsSync()) {
    return direct;
  }
  final txt = File('$outputPath.txt');
  if (txt.existsSync()) {
    return txt;
  }
  final parent = Directory(p.dirname(outputPath));
  final basename = p.basename(outputPath);
  await for (final entity in parent.list()) {
    if (entity is File && p.basename(entity.path).startsWith(basename)) {
      return entity;
    }
  }
  return direct;
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

class _ProcessOutput {
  const _ProcessOutput({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

final class _ToolCallingEngine implements sdk.LmEngine {
  @override
  Future<String> complete(sdk.LmCompletionRequest request) async {
    final result = await request.onToolCall?.call(
      'get_current_time',
      const <String, Object?>{},
    );
    return 'Tool returned: $result';
  }

  @override
  Future<String> completeStreaming(
    sdk.LmCompletionRequest request,
    void Function(String chunk) onChunk,
  ) async {
    final text = await complete(request);
    onChunk(text);
    return text;
  }
}

final class _GemmaToolLoopEngine implements sdk.LmEngine {
  @override
  Future<String> complete(sdk.LmCompletionRequest request) async {
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
    sdk.LmCompletionRequest request,
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

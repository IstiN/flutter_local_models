import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_models_flutter/local_models_flutter.dart';

const _manifest = LocalModelManifest(
  id: 'qwen3-8b-4bit',
  displayName: 'Qwen3 8B 4bit',
  description: 'General-purpose local Qwen text model.',
  runtimeAdapter: RuntimeAdapter.mlxLm,
  tasks: [ModelTask.chat, ModelTask.code],
  source: ModelSource(
    provider: 'huggingface',
    repo: 'mlx-community/Qwen3-8B-4bit',
    revision: 'main',
    license: 'apache-2.0',
  ),
  packaging: PackagingSpec(
    releaseTag: 'model-qwen3-8b-4bit',
    archiveName: 'qwen3-8b-4bit.tar',
    chunkSizeBytes: 1900000000,
    assetPrefix: 'qwen3-8b-4bit',
  ),
  requirements: SystemRequirements(
    platform: 'macos-apple-silicon',
    minMemoryGb: 16,
    recommendedMemoryGb: 24,
    notes: ['Balanced local text model'],
  ),
  capabilities: CapabilitySpec(
    audioInput: false,
    audioOutput: false,
    toolCalling: true,
  ),
);

const _ttsManifest = LocalModelManifest(
  id: 'kokoro-82m-4bit',
  displayName: 'Kokoro 82M 4bit',
  description: 'Compact local TTS model.',
  runtimeAdapter: RuntimeAdapter.mlxAudio,
  tasks: [ModelTask.textToSpeech, ModelTask.audioOutput],
  source: ModelSource(
    provider: 'huggingface',
    repo: 'mlx-community/Kokoro-82M-4bit',
    revision: 'main',
    license: 'apache-2.0',
  ),
  packaging: PackagingSpec(
    releaseTag: 'model-kokoro-82m-4bit',
    archiveName: 'kokoro-82m-4bit.tar',
    chunkSizeBytes: 1900000000,
    assetPrefix: 'kokoro-82m-4bit',
  ),
  requirements: SystemRequirements(
    platform: 'macos-apple-silicon',
    minMemoryGb: 4,
    recommendedMemoryGb: 8,
    notes: ['Tiny local TTS model'],
  ),
  capabilities: CapabilitySpec(
    audioInput: false,
    audioOutput: true,
    toolCalling: false,
  ),
  runtimeConfig: ModelRuntimeConfig(
    defaultParameters: {
      'audio_format': 'wav',
      'join_audio': true,
      'voice': 'af_heart',
    },
  ),
);

const _voxcpm2Manifest = LocalModelManifest(
  id: 'voxcpm2-4bit',
  displayName: 'VoxCPM2 4bit',
  description: 'Multilingual local TTS model.',
  runtimeAdapter: RuntimeAdapter.mlxAudio,
  tasks: [ModelTask.textToSpeech, ModelTask.audioOutput],
  source: ModelSource(
    provider: 'huggingface',
    repo: 'mlx-community/VoxCPM2-4bit',
    revision: 'main',
    license: 'apache-2.0',
  ),
  packaging: PackagingSpec(
    releaseTag: 'model-voxcpm2-4bit',
    archiveName: 'voxcpm2-4bit.tar',
    chunkSizeBytes: 1900000000,
    assetPrefix: 'voxcpm2-4bit',
  ),
  requirements: SystemRequirements(
    platform: 'macos-apple-silicon',
    minMemoryGb: 12,
    recommendedMemoryGb: 24,
    notes: ['Requires GitHub mlx-audio build'],
  ),
  capabilities: CapabilitySpec(
    audioInput: false,
    audioOutput: true,
    toolCalling: false,
  ),
  runtimeConfig: ModelRuntimeConfig(
    defaultParameters: {
      'audio_format': 'wav',
      'join_audio': true,
      'lang_code': 'en',
      'cfg_scale': 2.0,
      'ddpm_steps': 7,
      'max_tokens': 2000,
    },
  ),
);

class FakeStudioApiClient extends StudioApiClient {
  FakeStudioApiClient(this.details, this.files, {this.releaseManifest});

  final HuggingFaceRepoDetails details;
  final List<RemoteFileDescriptor> files;
  final LocalModelManifest? releaseManifest;

  @override
  Future<HuggingFaceRepoDetails> fetchHuggingFaceRepo(
    String repoId, {
    String revision = 'main',
    String? token,
  }) async {
    return details;
  }

  @override
  Future<List<RemoteFileDescriptor>?> hydrateFilesForTesting(
    HuggingFaceRepoDetails details, {
    String? token,
  }) async {
    return files;
  }

  @override
  Future<LocalModelManifest?> fetchReleaseManifest(
    GitHubReleaseRecord release,
  ) async {
    return releaseManifest;
  }
}

void main() {
  test(
    'reloadInstalledModels discovers metadata and delete removes model',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'local-models-studio-services-test',
      );
      addTearDown(() async {
        if (tempDirectory.existsSync()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      final paths = StudioPaths(baseDirectory: tempDirectory);
      final modelDirectory = Directory(
        '${paths.modelsDirectory.path}/${_manifest.id}',
      );
      await modelDirectory.create(recursive: true);
      await File(
        '${modelDirectory.path}/weights.bin',
      ).writeAsBytes([1, 2, 3, 4]);
      await File(
        '${modelDirectory.path}/.flutter_local_model.json',
      ).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'sourceLabel': 'Hugging Face',
          'installedAt': '2026-05-10T00:00:00.000Z',
          'manifest': {
            'id': 'qwen3-8b-4bit',
            'displayName': 'Qwen3 8B 4bit',
            'description': 'General-purpose local Qwen text model.',
            'runtimeAdapter': 'mlx_lm',
            'tasks': ['chat', 'code'],
            'source': {
              'provider': 'huggingface',
              'repo': 'mlx-community/Qwen3-8B-4bit',
              'revision': 'main',
              'license': 'apache-2.0',
            },
            'packaging': {
              'releaseTag': 'model-qwen3-8b-4bit',
              'archiveName': 'qwen3-8b-4bit.tar',
              'chunkSizeBytes': 1900000000,
              'assetPrefix': 'qwen3-8b-4bit',
            },
            'requirements': {
              'platform': 'macos-apple-silicon',
              'minMemoryGb': 16,
              'recommendedMemoryGb': 24,
              'notes': ['Balanced local text model'],
            },
            'capabilities': {
              'audioInput': false,
              'audioOutput': false,
              'toolCalling': true,
            },
          },
        }),
      );

      final controller = StudioController(
        registry: ModelRegistry(const [_manifest]),
        runtimeSummary: const NativeRuntimeSummary(
          bridgeVersion: 'test',
          platform: 'macOS test',
          metalAvailable: true,
          mlxFocused: true,
          ffiEnabled: true,
        ),
        paths: paths,
        refreshRemoteSourcesOnInitialize: false,
      );

      await controller.initialize();

      expect(controller.installedModels, hasLength(1));
      expect(
        controller.installedModels.first.manifest.displayName,
        'Qwen3 8B 4bit',
      );
      expect(controller.installedModels.first.chatSupported, isTrue);
      expect(controller.installedModels.first.sizeBytes, greaterThan(4));

      await controller.deleteInstalledModel(controller.installedModels.first);

      expect(controller.installedModels, isEmpty);
      expect(modelDirectory.existsSync(), isFalse);
    },
  );

  test('formatBytes and sanitizeId provide stable display helpers', () {
    expect(formatBytes(1024), '1 KB');
    expect(formatBytes(1536), '1.5 KB');
    expect(sanitizeId('mlx-community/Qwen3 8B!'), 'mlx-community-qwen3-8b');
  });

  test('LocalAudioRunner returns nested audio path from native bridge', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'local-models-studio-tts-test',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final nested = File(
      '${tempDirectory.path}/work/nested/generated.wav',
    );
    await nested.parent.create(recursive: true);
    await nested.writeAsBytes([
      0x52,
      0x49,
      0x46,
      0x46,
      0,
      0,
      0,
      0,
      0x57,
      0x41,
      0x56,
      0x45,
    ]);

    final dispatch = RecordingFlmDispatcher()
      ..onInvoke = (op, payload) {
        expect(op, 'audio.synthesize');
        expect(payload['text'], 'hello');
        return <String, Object?>{
          'ok': true,
          'outputAudioPath': nested.path,
        };
      };

    final modelDirectory = Directory('${tempDirectory.path}/model');
    await modelDirectory.create();
    final runner = LocalAudioRunner(
      engine: NativeAudioEngine(dispatch: dispatch),
    );
    final file = await runner.synthesizeSpeech(
      model: InstalledModel(
        manifest: _ttsManifest,
        directory: modelDirectory,
        sourceLabel: 'test',
        installedAt: DateTime.utc(2026, 5, 11),
        sizeBytes: 0,
      ),
      text: 'hello',
    );

    expect(file.path, nested.path);
    expect(await file.exists(), isTrue);
    expect(dispatch.calls.single.op, 'audio.synthesize');
  });

  test('LocalAudioRunner surfaces native TTS errors', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'local-models-studio-tts-error-test',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final dispatch = RecordingFlmDispatcher()
      ..onInvoke = (String op, Map<String, Object?> payload) {
        expect(op, 'audio.synthesize');
        return <String, Object?>{
          'ok': false,
          'error':
              "Native TTS failed: Import error: Kokoro requires the optional 'misaki' package.",
        };
      };

    final modelDirectory = Directory('${tempDirectory.path}/model');
    await modelDirectory.create();
    final runner = LocalAudioRunner(
      engine: NativeAudioEngine(dispatch: dispatch),
    );

    await expectLater(
      runner.synthesizeSpeech(
        model: InstalledModel(
          manifest: _ttsManifest,
          directory: modelDirectory,
          sourceLabel: 'test',
          installedAt: DateTime.utc(2026, 5, 11),
          sizeBytes: 0,
        ),
        text: 'hello',
      ),
      throwsA(
        isA<StateError>()
            .having(
              (error) => error.message,
              'message',
              contains('misaki'),
            ),
      ),
    );
  });

  test('LocalAudioRunner passes VoxCPM2 options to native bridge', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'local-models-studio-voxcpm2-payload-test',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final outFile = File('${tempDirectory.path}/generated.wav');
    await outFile.writeAsBytes([
      0x52,
      0x49,
      0x46,
      0x46,
      0,
      0,
      0,
      0,
      0x57,
      0x41,
      0x56,
      0x45,
    ]);

    final dispatch = RecordingFlmDispatcher()
      ..onInvoke = (op, payload) {
        expect(op, 'audio.synthesize');
        expect(payload['languageCode'], 'ru');
        expect(payload['referenceAudioPath'], '/tmp/reference.wav');
        expect(payload['referenceText'], 'reference words');
        expect(payload['cfg_scale'], 2.0);
        expect(payload['ddpm_steps'], 7);
        expect(payload['max_tokens'], 2000);
        return <String, Object?>{
          'ok': true,
          'outputAudioPath': outFile.path,
        };
      };

    final modelDirectory = Directory('${tempDirectory.path}/model');
    await modelDirectory.create();
    final runner = LocalAudioRunner(
      engine: NativeAudioEngine(dispatch: dispatch),
    );
    await runner.synthesizeSpeech(
      model: InstalledModel(
        manifest: _voxcpm2Manifest,
        directory: modelDirectory,
        sourceLabel: 'test',
        installedAt: DateTime.utc(2026, 5, 11),
        sizeBytes: 0,
      ),
      text: 'hello',
      options: const SpeechSynthesisOptions(
        languageCode: 'ru',
        referenceAudioPath: '/tmp/reference.wav',
        referenceText: 'reference words',
      ),
    );

    expect(dispatch.calls, hasLength(1));
  });

  test('LocalChatRunner passes thinking flag to native LM bridge', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'local-models-studio-thinking-payload-test',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final dispatch = RecordingFlmDispatcher()
      ..onInvoke = (op, payload) {
        expect(op, 'lm.generate');
        expect(payload['enableThinking'], false);
        return <String, Object?>{
          'ok': true,
          'text':
              '<think>hidden</think>hello',
        };
      };

    final modelDirectory = Directory('${tempDirectory.path}/model');
    await modelDirectory.create();
    final runner = LocalChatRunner(
      engine: NativeLmEngine(dispatch: dispatch),
    );
    final response = await runner.chatStream(
      model: InstalledModel(
        manifest: _manifest,
        directory: modelDirectory,
        sourceLabel: 'test',
        installedAt: DateTime.utc(2026, 5, 11),
        sizeBytes: 0,
      ),
      messages: [LocalChatMessage.user('hi')],
      onText: (_) {},
      params: const LocalChatParams(enableThinking: false),
    );

    expect(response, 'hello');
    expect(dispatch.calls.single.op, 'lm.generate');
  });

  test('LocalAudioRunner surfaces VoxCPM2 backend errors from bridge', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'local-models-studio-voxcpm2-error-test',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final dispatch = RecordingFlmDispatcher()
      ..onInvoke = (String op, Map<String, Object?> payload) {
        expect(op, 'audio.synthesize');
        expect(payload['text'], 'hello');
        return <String, Object?>{
          'ok': false,
          'error':
              'Error loading model: Model type voxcpm2 not supported for tts.',
        };
      };

    final modelDirectory = Directory('${tempDirectory.path}/model');
    await modelDirectory.create();
    final runner = LocalAudioRunner(
      engine: NativeAudioEngine(dispatch: dispatch),
    );

    await expectLater(
      runner.synthesizeSpeech(
        model: InstalledModel(
          manifest: _voxcpm2Manifest,
          directory: modelDirectory,
          sourceLabel: 'test',
          installedAt: DateTime.utc(2026, 5, 11),
          sizeBytes: 0,
        ),
        text: 'hello',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('voxcpm2'),
        ),
      ),
    );
  });

  test('settings persist source configuration', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'local-models-studio-settings-test',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final paths = StudioPaths(baseDirectory: tempDirectory);
    final firstController = StudioController(
      registry: ModelRegistry(const [_manifest]),
      runtimeSummary: const NativeRuntimeSummary(
        bridgeVersion: 'test',
        platform: 'macOS test',
        metalAvailable: true,
        mlxFocused: true,
        ffiEnabled: true,
      ),
      paths: paths,
      refreshRemoteSourcesOnInitialize: false,
    );
    await firstController.initialize();
    await firstController.updateSettings(
      hfToken: 'hf_test',
      githubRepoPath: 'TestOwner/test_repo',
      customHfRepoId: 'mlx-community/custom',
      maxDownloadRetries: 7,
    );

    final secondController = StudioController(
      registry: ModelRegistry(const [_manifest]),
      runtimeSummary: const NativeRuntimeSummary(
        bridgeVersion: 'test',
        platform: 'macOS test',
        metalAvailable: true,
        mlxFocused: true,
        ffiEnabled: true,
      ),
      paths: paths,
      refreshRemoteSourcesOnInitialize: false,
    );
    await secondController.initialize();

    expect(secondController.hfToken, 'hf_test');
    expect(secondController.githubRepoPath, 'TestOwner/test_repo');
    expect(secondController.customHfRepoId, 'mlx-community/custom');
    expect(secondController.maxDownloadRetries, 7);
  });

  test(
    'refreshInstalledModelMetadata updates only manifest metadata',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'local-models-studio-metadata-test',
      );
      addTearDown(() async {
        if (tempDirectory.existsSync()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      const updatedManifest = LocalModelManifest(
        id: 'qwen3-8b-4bit',
        displayName: 'Qwen3 8B 4bit',
        description: 'Updated runtime config metadata.',
        runtimeAdapter: RuntimeAdapter.mlxLm,
        tasks: [ModelTask.chat, ModelTask.code],
        source: ModelSource(
          provider: 'huggingface',
          repo: 'mlx-community/Qwen3-8B-4bit',
          revision: 'main',
          license: 'apache-2.0',
        ),
        packaging: PackagingSpec(
          releaseTag: 'model-qwen3-8b-4bit',
          archiveName: 'qwen3-8b-4bit.tar',
          chunkSizeBytes: 1900000000,
          assetPrefix: 'qwen3-8b-4bit',
        ),
        requirements: SystemRequirements(
          platform: 'macos-apple-silicon',
          minMemoryGb: 16,
          recommendedMemoryGb: 24,
          notes: ['Updated metadata only'],
        ),
        capabilities: CapabilitySpec(
          audioInput: false,
          audioOutput: false,
          toolCalling: true,
        ),
      );

      final paths = StudioPaths(baseDirectory: tempDirectory);
      final modelDirectory = Directory(
        '${paths.modelsDirectory.path}/${_manifest.id}',
      );
      await modelDirectory.create(recursive: true);
      final weightsFile = File('${modelDirectory.path}/weights.bin');
      await weightsFile.writeAsBytes([1, 2, 3, 4]);
      await File(
        '${modelDirectory.path}/.flutter_local_model.json',
      ).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'sourceLabel': 'GitHub Release',
          'installedAt': '2026-05-10T00:00:00.000Z',
          'manifest': {
            'id': 'qwen3-8b-4bit',
            'displayName': 'Qwen3 8B 4bit',
            'description': 'Old metadata.',
            'runtimeAdapter': 'mlx_lm',
            'tasks': ['chat', 'code'],
            'source': {
              'provider': 'huggingface',
              'repo': 'mlx-community/Qwen3-8B-4bit',
              'revision': 'main',
              'license': 'apache-2.0',
            },
            'packaging': {
              'releaseTag': 'model-qwen3-8b-4bit',
              'archiveName': 'qwen3-8b-4bit.tar',
              'chunkSizeBytes': 1900000000,
              'assetPrefix': 'qwen3-8b-4bit',
            },
            'requirements': {
              'platform': 'macos-apple-silicon',
              'minMemoryGb': 16,
              'recommendedMemoryGb': 24,
              'notes': ['Old metadata'],
            },
            'capabilities': {
              'audioInput': false,
              'audioOutput': false,
              'toolCalling': true,
            },
          },
        }),
      );

      final controller = StudioController(
        registry: ModelRegistry(const [updatedManifest]),
        runtimeSummary: const NativeRuntimeSummary(
          bridgeVersion: 'test',
          platform: 'macOS test',
          metalAvailable: true,
          mlxFocused: true,
          ffiEnabled: true,
        ),
        paths: paths,
        refreshRemoteSourcesOnInitialize: false,
      );
      await controller.initialize();

      final updated = await controller.refreshInstalledModelMetadata(
        controller.installedModels.single,
      );

      expect(await weightsFile.exists(), isTrue);
      expect(updated.manifest.description, 'Updated runtime config metadata.');
      expect(updated.sourceLabel, 'GitHub Release');
      expect(
        updated.installedAt.toUtc().toIso8601String(),
        startsWith('2026-05-10'),
      );
      expect(updated.metadataUpdatedAt, isNotNull);
    },
  );

  test('initialize restores persisted downloads and resumes them', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'local-models-studio-resume-test',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final sourceFile = File('${tempDirectory.path}/remote-weights.bin');
    await sourceFile.writeAsBytes(List<int>.generate(32, (index) => index));
    final details = HuggingFaceRepoDetails(
      repoId: _manifest.source.repo,
      revision: 'main',
      gated: false,
      pipelineTag: 'text-generation',
      files: [
        RemoteFileDescriptor(
          relativePath: 'weights.bin',
          downloadUri: sourceFile.uri,
          sizeBytes: await sourceFile.length(),
        ),
      ],
    );
    final paths = StudioPaths(baseDirectory: tempDirectory);
    final apiClient = FakeStudioApiClient(details, details.files);

    final firstController = StudioController(
      registry: ModelRegistry(const [_manifest]),
      runtimeSummary: const NativeRuntimeSummary(
        bridgeVersion: 'test',
        platform: 'macOS test',
        metalAvailable: true,
        mlxFocused: true,
        ffiEnabled: true,
      ),
      paths: paths,
      apiClient: apiClient,
      refreshRemoteSourcesOnInitialize: false,
    );
    await firstController.initialize();
    await firstController.startManifestHuggingFaceDownload(_manifest);

    expect(paths.downloadQueueFile.existsSync(), isTrue);

    final task = firstController.downloads.single;
    task.pauseRequested = true;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final secondController = StudioController(
      registry: ModelRegistry(const [_manifest]),
      runtimeSummary: const NativeRuntimeSummary(
        bridgeVersion: 'test',
        platform: 'macOS test',
        metalAvailable: true,
        mlxFocused: true,
        ffiEnabled: true,
      ),
      paths: paths,
      apiClient: apiClient,
      refreshRemoteSourcesOnInitialize: false,
    );
    await secondController.initialize();

    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(secondController.installedModels, hasLength(1));
    expect(
      File(
        '${paths.modelsDirectory.path}/${_manifest.id}/weights.bin',
      ).existsSync(),
      isTrue,
    );
    expect(secondController.downloads, isEmpty);
    expect(paths.downloadQueueFile.existsSync(), isFalse);
  });
}

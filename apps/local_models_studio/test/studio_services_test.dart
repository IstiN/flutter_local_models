import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_models_core/local_models_core.dart';
import 'package:local_models_studio/studio_services.dart';

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

      const manifest = LocalModelManifest(
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

      final paths = StudioPaths(baseDirectory: tempDirectory);
      final modelDirectory = Directory(
        '${paths.modelsDirectory.path}/${manifest.id}',
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
        registry: ModelRegistry(const [manifest]),
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
}

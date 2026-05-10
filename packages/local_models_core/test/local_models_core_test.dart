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
''';

void main() {
  test('parses yaml manifests', () {
    final manifest = LocalModelManifest.fromYaml(_sampleManifest);
    expect(manifest.id, 'qwen3-asr-0.6b-4bit');
    expect(manifest.runtimeAdapter, RuntimeAdapter.mlxAudio);
    expect(manifest.tasks, [ModelTask.speechToText]);
    expect(manifest.capabilities.audioInput, isTrue);
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
    );
    expect(LocalChatParams.fromJsonMap(params.toJson()).maxTokens, 128);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_models_core/local_models_core.dart';
import 'package:local_models_flutter/local_models_flutter.dart';

import 'fixtures/minimal_wav.dart';
import 'support/e2e_tiny_mlx_dispatch.dart';

const _tinyAsrManifest = LocalModelManifest(
  id: 'whisper-tiny-asr-4bit',
  displayName: 'Whisper Tiny ASR 4bit',
  description: 'E2E tiny ASR fixture.',
  runtimeAdapter: RuntimeAdapter.mlxAudio,
  tasks: [ModelTask.speechToText, ModelTask.audioInput],
  source: ModelSource(
    provider: 'huggingface',
    repo: 'mlx-community/whisper-tiny-asr-4bit',
    revision: 'main',
    license: 'apache-2.0',
  ),
  packaging: PackagingSpec(
    releaseTag: 'model-whisper-tiny-asr-4bit',
    archiveName: 'whisper-tiny-asr-4bit.tar',
    chunkSizeBytes: 1900000000,
    assetPrefix: 'whisper-tiny-asr-4bit',
  ),
  requirements: SystemRequirements(
    platform: 'macos-apple-silicon',
    minMemoryGb: 4,
    recommendedMemoryGb: 8,
    notes: ['E2E'],
  ),
  capabilities: CapabilitySpec(
    audioInput: true,
    audioOutput: false,
    toolCalling: false,
  ),
  runtimeConfig: ModelRuntimeConfig(
    defaultParameters: {
      'task': 'transcribe',
      'language': 'auto',
    },
  ),
);

const _tinyLmManifest = LocalModelManifest(
  id: 'qwen3-0.6b-4bit',
  displayName: 'Qwen3 0.6B 4bit',
  description: 'E2E tiny LM fixture.',
  runtimeAdapter: RuntimeAdapter.mlxLm,
  tasks: [ModelTask.chat],
  source: ModelSource(
    provider: 'huggingface',
    repo: 'mlx-community/Qwen3-0.6B-4bit',
    revision: 'main',
    license: 'apache-2.0',
  ),
  packaging: PackagingSpec(
    releaseTag: 'model-qwen3-0.6b-4bit',
    archiveName: 'qwen3-0.6b-4bit.tar',
    chunkSizeBytes: 1900000000,
    assetPrefix: 'qwen3-0.6b-4bit',
  ),
  requirements: SystemRequirements(
    platform: 'macos-apple-silicon',
    minMemoryGb: 4,
    recommendedMemoryGb: 8,
    notes: ['E2E'],
  ),
  capabilities: CapabilitySpec(
    audioInput: false,
    audioOutput: false,
    toolCalling: true,
  ),
);

const _tinyTtsManifest = LocalModelManifest(
  id: 'kokoro-82m-4bit',
  displayName: 'Kokoro 82M 4bit',
  description: 'E2E tiny TTS fixture.',
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
    notes: ['E2E'],
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

void main() {
  test(
    'E2E voice pipeline: tiny ASR → tiny LM → tiny TTS via native engine contract',
    () async {
      final root = await Directory.systemTemp.createTemp('flm-voice-e2e-');
      addTearDown(() async {
        if (root.existsSync()) {
          await root.delete(recursive: true);
        }
      });

      final userWav = File('${root.path}/user_input.wav');
      await userWav.writeAsBytes(minimalWavMono16k());

      final asrDir = Directory('${root.path}/asr')..createSync();
      final chatDir = Directory('${root.path}/chat')..createSync();
      final ttsDir = Directory('${root.path}/tts')..createSync();

      final installedAt = DateTime.utc(2026, 5, 11);
      final asr = InstalledModel(
        manifest: _tinyAsrManifest,
        directory: asrDir,
        sourceLabel: 'e2e',
        installedAt: installedAt,
        sizeBytes: 0,
      );
      final chat = InstalledModel(
        manifest: _tinyLmManifest,
        directory: chatDir,
        sourceLabel: 'e2e',
        installedAt: installedAt,
        sizeBytes: 0,
      );
      final tts = InstalledModel(
        manifest: _tinyTtsManifest,
        directory: ttsDir,
        sourceLabel: 'e2e',
        installedAt: installedAt,
        sizeBytes: 0,
      );

      final dispatch = E2eTinyMlxDispatcher(
        transcript: 'hello from tiny asr',
        assistantReply: 'hello from tiny lm',
      );

      final audioRunner = LocalAudioRunner(
        engine: NativeAudioEngine(dispatch: dispatch),
      );
      final chatRunner = LocalChatRunner(
        engine: NativeLmEngine(dispatch: dispatch),
      );

      final result = await Voice2VoicePipeline.run(
        audioRunner: audioRunner,
        chatRunner: chatRunner,
        asrModel: asr,
        chatModel: chat,
        ttsModel: tts,
        userAudioPath: userWav.path,
        instruction: 'Reply politely.',
        chatParams: const LocalChatParams(maxTokens: 64),
      );

      expect(result.transcript, 'hello from tiny asr');
      expect(result.assistantText, 'hello from tiny lm');
      expect(result.synthesizedAudio, isNotEmpty);
      expect(result.synthesizedAudio.length, greaterThan(44));

      expect(dispatch.calls.length, 3);
      expect(dispatch.calls[0].op, 'audio.transcribe');
      expect(dispatch.calls[0].payload['audioPath'], userWav.path);
      expect(dispatch.calls[0].payload['modelPath'], asrDir.path);

      expect(dispatch.calls[1].op, 'lm.generate');
      final prompt = dispatch.calls[1].payload['prompt'] as String?;
      expect(prompt, isNotNull);
      expect(prompt!, contains('hello from tiny asr'));
      expect(prompt, contains('Instruction: Reply politely.'));

      expect(dispatch.calls[2].op, 'audio.synthesize');
      expect(dispatch.calls[2].payload['text'], 'hello from tiny lm');
      expect(dispatch.calls[2].payload['manifestId'], 'kokoro-82m-4bit');
    },
  );
}

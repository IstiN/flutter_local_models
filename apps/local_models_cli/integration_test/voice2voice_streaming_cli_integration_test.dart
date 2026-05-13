import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:local_models_sdk/local_models_sdk.dart' as sdk;
import 'package:test/test.dart';

const _manifest = sdk.LocalModelManifest(
  id: 'cli-voice2voice-streaming-test',
  displayName: 'CLI Voice2Voice Streaming Test',
  description: 'fixture',
  runtimeAdapter: sdk.RuntimeAdapter.mlxLm,
  tasks: [sdk.ModelTask.chat],
  source: sdk.ModelSource(
    provider: 'local',
    repo: 'test/voice2voice',
    revision: 'main',
    license: 'mit',
  ),
  packaging: sdk.PackagingSpec(
    releaseTag: 'test',
    archiveName: 'test.tar',
    chunkSizeBytes: 1,
    assetPrefix: 'test',
  ),
  requirements: sdk.SystemRequirements(
    platform: 'macos',
    minMemoryGb: 1,
    recommendedMemoryGb: 1,
    notes: [],
  ),
  capabilities: sdk.CapabilitySpec(
    audioInput: true,
    audioOutput: true,
    toolCalling: false,
  ),
);

void main() {
  test('CLI SDK streams voice to ASR to LLM to TTS with low latency', () async {
    final ttsStarted = Completer<void>();
    final chatFinished = Completer<void>();
    final pipeline = sdk.StreamingVoice2VoicePipeline(
      asrEngine: _FakeAsr(),
      chatRunner: sdk.LocalChatRunner(
        engine: _FakeChat(ttsStarted: ttsStarted, chatFinished: chatFinished),
      ),
      ttsEngine: _FakeTts(ttsStarted: ttsStarted),
    );
    final model = _installed();

    final events = await pipeline
        .run(
          asrModel: model,
          chatModel: model,
          ttsModel: model,
          userAudio: Stream.fromIterable([
            sdk.VoiceAudioChunk(bytes: Uint8List.fromList([1, 2])),
            sdk.VoiceAudioChunk(bytes: Uint8List(0), isFinal: true),
          ]),
          instruction: 'Keep it short.',
          ttsCoalescing: const sdk.VoiceTtsCoalescing.immediate(),
        )
        .toList();

    expect(chatFinished.isCompleted, isTrue);
    final firstAudio = events.indexWhere(
      (event) => event.type == sdk.Voice2VoiceEventType.ttsAudio,
    );
    final assistantFinal = events.indexWhere(
      (event) => event.type == sdk.Voice2VoiceEventType.assistantFinal,
    );
    expect(firstAudio, greaterThanOrEqualTo(0));
    expect(assistantFinal, greaterThanOrEqualTo(0));
    expect(firstAudio, lessThan(assistantFinal));
    expect(events.last.type, sdk.Voice2VoiceEventType.done);
  });
}

sdk.InstalledModel _installed() {
  return sdk.InstalledModel(
    manifest: _manifest,
    directory: Directory('/tmp/${_manifest.id}'),
    sourceLabel: 'integration_test',
    installedAt: DateTime.utc(2026, 5, 13),
    sizeBytes: 1,
  );
}

final class _FakeAsr implements sdk.StreamingAsrEngine {
  @override
  Stream<sdk.StreamingAsrTranscript> transcribeStream({
    required sdk.InstalledModel model,
    required Stream<sdk.VoiceAudioChunk> audio,
    String? language,
  }) async* {
    await audio.drain<void>();
    yield const sdk.StreamingAsrTranscript(text: 'voice text', isFinal: true);
  }
}

final class _FakeChat implements sdk.LmEngine {
  _FakeChat({required this.ttsStarted, required this.chatFinished});

  final Completer<void> ttsStarted;
  final Completer<void> chatFinished;

  @override
  Future<String> complete(sdk.LmCompletionRequest request) async {
    throw UnimplementedError();
  }

  @override
  Future<String> completeStreaming(
    sdk.LmCompletionRequest request,
    void Function(String chunk) onChunk,
  ) async {
    expect(request.prompt, contains('voice text'));
    onChunk('streamed');
    await ttsStarted.future.timeout(const Duration(seconds: 2));
    onChunk(' answer');
    chatFinished.complete();
    return 'streamed answer';
  }
}

final class _FakeTts implements sdk.StreamingTtsEngine {
  _FakeTts({required this.ttsStarted});

  final Completer<void> ttsStarted;

  @override
  Stream<sdk.VoiceAudioChunk> synthesizeStream({
    required sdk.InstalledModel model,
    required Stream<String> text,
    sdk.VoiceSynthesisOptions options = const sdk.VoiceSynthesisOptions(),
  }) async* {
    await for (final chunk in text) {
      if (!ttsStarted.isCompleted) {
        ttsStarted.complete();
      }
      yield sdk.VoiceAudioChunk(bytes: Uint8List.fromList(chunk.codeUnits));
    }
    yield sdk.VoiceAudioChunk(bytes: Uint8List(0), isFinal: true);
  }
}

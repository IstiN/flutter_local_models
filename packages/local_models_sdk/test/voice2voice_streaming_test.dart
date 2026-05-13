import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:local_models_sdk/local_models_sdk.dart';
import 'package:test/test.dart';

const _asrManifest = LocalModelManifest(
  id: 'test-asr',
  displayName: 'Test ASR',
  description: 'fixture',
  runtimeAdapter: RuntimeAdapter.mlxAudio,
  tasks: [ModelTask.speechToText],
  source: ModelSource(
    provider: 'local',
    repo: 'test/asr',
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
    platform: 'macos',
    minMemoryGb: 1,
    recommendedMemoryGb: 1,
    notes: [],
  ),
  capabilities: CapabilitySpec(
    audioInput: true,
    audioOutput: false,
    toolCalling: false,
  ),
);

const _chatManifest = LocalModelManifest(
  id: 'test-chat',
  displayName: 'Test Chat',
  description: 'fixture',
  runtimeAdapter: RuntimeAdapter.mlxLm,
  tasks: [ModelTask.chat],
  source: ModelSource(
    provider: 'local',
    repo: 'test/chat',
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
    platform: 'macos',
    minMemoryGb: 1,
    recommendedMemoryGb: 1,
    notes: [],
  ),
  capabilities: CapabilitySpec(
    audioInput: false,
    audioOutput: false,
    toolCalling: false,
  ),
);

const _ttsManifest = LocalModelManifest(
  id: 'test-tts',
  displayName: 'Test TTS',
  description: 'fixture',
  runtimeAdapter: RuntimeAdapter.mlxAudio,
  tasks: [ModelTask.textToSpeech],
  source: ModelSource(
    provider: 'local',
    repo: 'test/tts',
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
    platform: 'macos',
    minMemoryGb: 1,
    recommendedMemoryGb: 1,
    notes: [],
  ),
  capabilities: CapabilitySpec(
    audioInput: false,
    audioOutput: true,
    toolCalling: false,
  ),
);

void main() {
  test('pipeline streams LLM text into TTS before LLM completes', () async {
    final ttsStarted = Completer<void>();
    final chatFinished = Completer<void>();
    final pipeline = StreamingVoice2VoicePipeline(
      asrEngine: _FakeStreamingAsr(),
      chatRunner: LocalChatRunner(
        engine: _FakeStreamingChatEngine(
          ttsStarted: ttsStarted,
          chatFinished: chatFinished,
        ),
      ),
      ttsEngine: _FakeStreamingTts(ttsStarted: ttsStarted),
    );

    final events = await pipeline
        .run(
          asrModel: _installed(_asrManifest),
          chatModel: _installed(_chatManifest),
          ttsModel: _installed(_ttsManifest),
          userAudio: Stream.value(
            VoiceAudioChunk(bytes: Uint8List.fromList([1, 2, 3])),
          ),
          instruction: 'Reply briefly.',
          ttsCoalescing: const VoiceTtsCoalescing.immediate(),
        )
        .toList();

    expect(chatFinished.isCompleted, isTrue);
    expect(
      events.map((event) => event.type),
      contains(Voice2VoiceEventType.asrFinal),
    );
    expect(
      events.map((event) => event.type),
      contains(Voice2VoiceEventType.assistantDelta),
    );
    expect(
      events.map((event) => event.type),
      contains(Voice2VoiceEventType.ttsAudio),
    );
    expect(events.last.type, Voice2VoiceEventType.done);

    final firstTtsIndex = events.indexWhere(
      (event) => event.type == Voice2VoiceEventType.ttsAudio,
    );
    final assistantFinalIndex = events.indexWhere(
      (event) => event.type == Voice2VoiceEventType.assistantFinal,
    );
    expect(firstTtsIndex, greaterThanOrEqualTo(0));
    expect(assistantFinalIndex, greaterThanOrEqualTo(0));
    expect(firstTtsIndex, lessThan(assistantFinalIndex));
  });

  test('cancel token emits cancelled and skips done', () async {
    final holdChat = Completer<void>();
    final ttsStarted = Completer<void>()..complete();
    final pipeline = StreamingVoice2VoicePipeline(
      asrEngine: _FakeStreamingAsr(),
      chatRunner: LocalChatRunner(engine: _HoldingChatEngine(holdChat)),
      ttsEngine: _FakeStreamingTts(ttsStarted: ttsStarted),
    );
    final token = Voice2VoiceCancelToken();
    final eventsFuture = pipeline
        .run(
          asrModel: _installed(_asrManifest),
          chatModel: _installed(_chatManifest),
          ttsModel: _installed(_ttsManifest),
          userAudio: Stream.value(
            VoiceAudioChunk(bytes: Uint8List.fromList([1])),
          ),
          cancelToken: token,
          ttsCoalescing: const VoiceTtsCoalescing.immediate(),
        )
        .toList();

    await Future<void>.delayed(Duration.zero);
    token.cancel();
    holdChat.complete();

    final events = await eventsFuture;
    expect(
      events.map((e) => e.type),
      contains(Voice2VoiceEventType.cancelled),
    );
    expect(
      events.any((e) => e.type == Voice2VoiceEventType.done),
      isFalse,
    );
  });

  test('coalesceTtsText immediate forwards each delta', () async {
    final out = await coalesceTtsText(
      Stream.fromIterable(['a', 'b']),
      const VoiceTtsCoalescing.immediate(),
    ).toList();
    expect(out, ['a', 'b']);
  });

  test('coalesceTtsText flushes on sentence end', () async {
    final c = StreamController<String>();
    final coalescing = VoiceTtsCoalescing(
      flushDelay: const Duration(days: 1),
      minCharsBeforeSentenceFlush: 1,
      maxCharsPerSegment: 1000,
    );
    final future = coalesceTtsText(c.stream, coalescing).toList();
    c.add('Hi.');
    await Future<void>.delayed(Duration.zero);
    await c.close();
    expect(await future, ['Hi.']);
  });

  test('coalesceTtsText singleUtterancePerReply emits once on close', () async {
    final c = StreamController<String>();
    final future = coalesceTtsText(
      c.stream,
      const VoiceTtsCoalescing.singleUtterancePerReply(),
    ).toList();
    c.add('Hello ');
    c.add('world.');
    await Future<void>.delayed(Duration.zero);
    await c.close();
    expect(await future, ['Hello world.']);
  });
}

InstalledModel _installed(LocalModelManifest manifest) {
  return InstalledModel(
    manifest: manifest,
    directory: Directory('/tmp/${manifest.id}'),
    sourceLabel: 'test',
    installedAt: DateTime.utc(2026, 5, 13),
    sizeBytes: 1,
  );
}

final class _FakeStreamingAsr implements StreamingAsrEngine {
  @override
  Stream<StreamingAsrTranscript> transcribeStream({
    required InstalledModel model,
    required Stream<VoiceAudioChunk> audio,
    String? language,
  }) async* {
    await audio.drain<void>();
    yield const StreamingAsrTranscript(text: 'hello', isFinal: false);
    yield const StreamingAsrTranscript(text: 'hello world', isFinal: true);
  }
}

final class _HoldingChatEngine implements LmEngine {
  _HoldingChatEngine(this._hold);

  final Completer<void> _hold;

  @override
  Future<String> complete(LmCompletionRequest request) async {
    throw UnimplementedError();
  }

  @override
  Future<String> completeStreaming(
    LmCompletionRequest request,
    void Function(String chunk) onChunk,
  ) async {
    await _hold.future;
    onChunk('done');
    return 'done';
  }
}

final class _FakeStreamingChatEngine implements LmEngine {
  _FakeStreamingChatEngine({
    required this.ttsStarted,
    required this.chatFinished,
  });

  final Completer<void> ttsStarted;
  final Completer<void> chatFinished;

  @override
  Future<String> complete(LmCompletionRequest request) async {
    throw UnimplementedError();
  }

  @override
  Future<String> completeStreaming(
    LmCompletionRequest request,
    void Function(String chunk) onChunk,
  ) async {
    expect(request.prompt, contains('hello world'));
    onChunk('Hi');
    await ttsStarted.future.timeout(const Duration(seconds: 2));
    onChunk(' there');
    chatFinished.complete();
    return 'Hi there';
  }
}

final class _FakeStreamingTts implements StreamingTtsEngine {
  _FakeStreamingTts({required this.ttsStarted});

  final Completer<void> ttsStarted;

  @override
  Stream<VoiceAudioChunk> synthesizeStream({
    required InstalledModel model,
    required Stream<String> text,
    VoiceSynthesisOptions options = const VoiceSynthesisOptions(),
  }) async* {
    await for (final chunk in text) {
      if (!ttsStarted.isCompleted) {
        ttsStarted.complete();
      }
      yield VoiceAudioChunk(
        bytes: Uint8List.fromList(chunk.codeUnits),
        mediaType: 'audio/test',
      );
    }
    yield VoiceAudioChunk(bytes: Uint8List(0), isFinal: true);
  }
}

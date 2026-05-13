import 'dart:async';
import 'dart:typed_data';

import 'package:local_models_core/local_models_core.dart';

import 'model_store.dart';
import 'runtime.dart';

/// Console breadcrumb for tracing ASR → LLM → TTS; filter logs with `VoiceUX:chain`.
void _voicePipelineChainLog(String message) {
  // ignore: avoid_print
  print('[VoiceUX:chain] $message');
}

String _voicePipelineChainPreview(String text, int maxChars) {
  final s = text.replaceAll('\n', ' ').trim();
  if (s.length <= maxChars) {
    return s;
  }
  return '${s.substring(0, maxChars)}…';
}

String _voicePipelineCoalescingLabel(VoiceTtsCoalescing c) {
  if (c.flushEveryDelta) {
    return 'immediate_deltas';
  }
  if (c.maxCharsPerSegment >= 100000) {
    return 'single_utterance_per_reply';
  }
  return 'phrase_coalesce(maxChars=${c.maxCharsPerSegment})';
}

class VoiceAudioChunk {
  const VoiceAudioChunk({
    required this.bytes,
    this.isFinal = false,
    this.mediaType,
    this.sampleRate,
  });

  final Uint8List bytes;
  final bool isFinal;
  final String? mediaType;
  final int? sampleRate;
}

class StreamingAsrTranscript {
  const StreamingAsrTranscript({required this.text, this.isFinal = false});

  final String text;
  final bool isFinal;
}

/// Stop [StreamingVoice2VoicePipeline] early (LLM / TTS may still finish in the
/// background; the UI stream emits [Voice2VoiceEventType.cancelled] and closes).
final class Voice2VoiceCancelToken {
  final Completer<void> _completer = Completer<void>();
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  /// Completes when [cancel] is called (at most once).
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

/// Thrown internally when [Voice2VoiceCancelToken] wins a race against chat/TTS.
class VoicePipelineCancelled implements Exception {
  const VoicePipelineCancelled();
}

enum Voice2VoiceEventType {
  asrPartial,
  asrFinal,
  assistantDelta,
  assistantFinal,
  ttsAudio,
  cancelled,
  done,
}

class Voice2VoiceStreamEvent {
  const Voice2VoiceStreamEvent._({required this.type, this.text, this.audio});

  const Voice2VoiceStreamEvent.asrPartial(String text)
    : this._(type: Voice2VoiceEventType.asrPartial, text: text);

  const Voice2VoiceStreamEvent.asrFinal(String text)
    : this._(type: Voice2VoiceEventType.asrFinal, text: text);

  const Voice2VoiceStreamEvent.assistantDelta(String text)
    : this._(type: Voice2VoiceEventType.assistantDelta, text: text);

  const Voice2VoiceStreamEvent.assistantFinal(String text)
    : this._(type: Voice2VoiceEventType.assistantFinal, text: text);

  const Voice2VoiceStreamEvent.ttsAudio(VoiceAudioChunk audio)
    : this._(type: Voice2VoiceEventType.ttsAudio, audio: audio);

  const Voice2VoiceStreamEvent.cancelled()
    : this._(type: Voice2VoiceEventType.cancelled);

  const Voice2VoiceStreamEvent.done() : this._(type: Voice2VoiceEventType.done);

  final Voice2VoiceEventType type;
  final String? text;
  final VoiceAudioChunk? audio;
}

abstract interface class StreamingAsrEngine {
  Stream<StreamingAsrTranscript> transcribeStream({
    required InstalledModel model,
    required Stream<VoiceAudioChunk> audio,
    String? language,
  });
}

abstract interface class StreamingTtsEngine {
  Stream<VoiceAudioChunk> synthesizeStream({
    required InstalledModel model,
    required Stream<String> text,
    VoiceSynthesisOptions options = const VoiceSynthesisOptions(),
  });
}

/// Buffers raw LLM token/text deltas into segments suitable for TTS so the
/// model gets phrase-sized input without waiting for the full assistant reply.
///
/// Use [VoiceTtsCoalescing.immediate] in tests or when the LLM already yields
/// whole phrases.
class VoiceTtsCoalescing {
  const VoiceTtsCoalescing({
    this.flushDelay = const Duration(milliseconds: 180),
    this.minCharsBeforeSentenceFlush = 8,
    this.maxCharsPerSegment = 200,
    this.flushEveryDelta = false,
  });

  /// Forward each non-empty delta to TTS as soon as it arrives.
  const VoiceTtsCoalescing.immediate()
    : flushDelay = Duration.zero,
      minCharsBeforeSentenceFlush = 0,
      maxCharsPerSegment = 1 << 30,
      flushEveryDelta = true;

  /// Coalesce the full assistant reply into a single TTS segment.
  ///
  /// Use for **VoiceDesign**, voice **clone**, and similar checkpoints where
  /// phrase-wise synthesis drops speaker context and later chunks sound like
  /// a generic/default voice.
  const VoiceTtsCoalescing.singleUtterancePerReply()
    : flushDelay = const Duration(days: 365),
      minCharsBeforeSentenceFlush = 200000,
      maxCharsPerSegment = 200000,
      flushEveryDelta = false;

  final Duration flushDelay;
  final int minCharsBeforeSentenceFlush;
  final int maxCharsPerSegment;
  final bool flushEveryDelta;
}

/// Turns a stream of LLM deltas into TTS segments (debounce + sentence break).
Stream<String> coalesceTtsText(
  Stream<String> deltas,
  VoiceTtsCoalescing c,
) {
  late final StreamSubscription<String> sub;
  final controller = StreamController<String>(
    onCancel: () => sub.cancel(),
  );

  if (c.flushEveryDelta) {
    sub = deltas.listen(
      (d) {
        if (d.isNotEmpty) {
          controller.add(d);
        }
      },
      onError: controller.addError,
      onDone: controller.close,
      cancelOnError: true,
    );
    return controller.stream;
  }

  final buffer = StringBuffer();
  Timer? debounce;

  bool isSentenceEnd(String s) {
    final t = s.trimRight();
    if (t.isEmpty) {
      return false;
    }
    final last = t.codeUnitAt(t.length - 1);
    return last == 0x2E ||
        last == 0x21 ||
        last == 0x3F ||
        last == 0x2026;
  }

  void emitTrimmed(String trimmed) {
    if (trimmed.isEmpty) {
      return;
    }
    debounce?.cancel();
    debounce = null;
    controller.add(trimmed);
  }

  sub = deltas.listen(
    (delta) {
      buffer.write(delta);
      var trimmed = buffer.toString().trim();
      if (trimmed.isEmpty) {
        return;
      }

      if (trimmed.length >= c.maxCharsPerSegment) {
        final head = trimmed.substring(0, c.maxCharsPerSegment);
        final tail = trimmed.substring(c.maxCharsPerSegment).trimLeft();
        buffer
          ..clear()
          ..write(tail);
        emitTrimmed(head);
        return;
      }

      if (trimmed.length >= c.minCharsBeforeSentenceFlush &&
          isSentenceEnd(trimmed)) {
        buffer.clear();
        emitTrimmed(trimmed);
        return;
      }

      debounce?.cancel();
      debounce = Timer(c.flushDelay, () {
        final t = buffer.toString().trim();
        buffer.clear();
        debounce = null;
        if (t.isNotEmpty) {
          controller.add(t);
        }
      });
    },
    onError: controller.addError,
    onDone: () {
      debounce?.cancel();
      final t = buffer.toString().trim();
      buffer.clear();
      if (t.isNotEmpty) {
        controller.add(t);
      }
      controller.close();
    },
    cancelOnError: true,
  );
  return controller.stream;
}

class VoiceSynthesisOptions {
  const VoiceSynthesisOptions({
    this.voice = 'Ryan',
    this.languageCode = 'auto',
    this.speed,
    this.referenceAudioPath,
    this.referenceText,
    this.temperature,
    this.streamingInterval,
    this.workerScriptPath,
    this.pythonExecutable,
    this.workerVerbose = false,
    this.maxTokens,
    this.instruct,
  });

  final String voice;
  final String languageCode;
  final double? speed;
  final String? referenceAudioPath;
  final String? referenceText;
  final double? temperature;
  final double? streamingInterval;
  final String? workerScriptPath;
  final String? pythonExecutable;
  final bool workerVerbose;
  final int? maxTokens;
  final String? instruct;
}

class StreamingVoice2VoicePipeline {
  const StreamingVoice2VoicePipeline({
    required StreamingAsrEngine asrEngine,
    required StreamingChatRunner chatRunner,
    required StreamingTtsEngine ttsEngine,
  }) : _asrEngine = asrEngine,
       _chatRunner = chatRunner,
       _ttsEngine = ttsEngine;

  final StreamingAsrEngine _asrEngine;
  final StreamingChatRunner _chatRunner;
  final StreamingTtsEngine _ttsEngine;

  Stream<Voice2VoiceStreamEvent> run({
    required InstalledModel asrModel,
    required InstalledModel chatModel,
    required InstalledModel ttsModel,
    required Stream<VoiceAudioChunk> userAudio,
    String instruction = '',
    String? asrLanguage,
    LocalChatParams chatParams = const LocalChatParams(),
    LmToolRegistry? chatToolRegistry,
    VoiceSynthesisOptions ttsOptions = const VoiceSynthesisOptions(),
    VoiceTtsCoalescing ttsCoalescing = const VoiceTtsCoalescing(),
    Voice2VoiceCancelToken? cancelToken,
  }) {
    final events = StreamController<Voice2VoiceStreamEvent>();
    unawaited(
      _run(
        events: events,
        asrModel: asrModel,
        chatModel: chatModel,
        ttsModel: ttsModel,
        userAudio: userAudio,
        instruction: instruction,
        asrLanguage: asrLanguage,
        chatParams: chatParams,
        chatToolRegistry: chatToolRegistry,
        ttsOptions: ttsOptions,
        ttsCoalescing: ttsCoalescing,
        cancelToken: cancelToken,
      ),
    );
    return events.stream;
  }

  Future<void> _run({
    required StreamController<Voice2VoiceStreamEvent> events,
    required InstalledModel asrModel,
    required InstalledModel chatModel,
    required InstalledModel ttsModel,
    required Stream<VoiceAudioChunk> userAudio,
    required String instruction,
    required String? asrLanguage,
    required LocalChatParams chatParams,
    required LmToolRegistry? chatToolRegistry,
    required VoiceSynthesisOptions ttsOptions,
    required VoiceTtsCoalescing ttsCoalescing,
    required Voice2VoiceCancelToken? cancelToken,
  }) async {
    Future<void> onUserCancel() async {
      _voicePipelineChainLog('pipeline_cancelled');
      events.add(const Voice2VoiceStreamEvent.cancelled());
    }

    try {
      if (cancelToken?.isCancelled ?? false) {
        await onUserCancel();
        return;
      }
      _voicePipelineChainLog(
        'pipeline_begin | asr=${asrModel.manifest.id} | chat=${chatModel.manifest.id} | '
        'tts=${ttsModel.manifest.id}',
      );
      _voicePipelineChainLog(
        'tts_user_settings | speaker="${ttsOptions.voice}" | '
        'lang=${ttsOptions.languageCode} | speed=${ttsOptions.speed} | '
        'instructLen=${ttsOptions.instruct?.length ?? 0} | '
        'refAudio=${ttsOptions.referenceAudioPath != null && ttsOptions.referenceAudioPath!.trim().isNotEmpty} | '
        'coalescing=${_voicePipelineCoalescingLabel(ttsCoalescing)}',
      );
      String transcript = '';
      await for (final update in _asrEngine.transcribeStream(
        model: asrModel,
        audio: userAudio,
        language: asrLanguage,
      )) {
        transcript = update.text;
        events.add(
          update.isFinal
              ? Voice2VoiceStreamEvent.asrFinal(update.text)
              : Voice2VoiceStreamEvent.asrPartial(update.text),
        );
        if (update.isFinal) {
          break;
        }
      }

      _voicePipelineChainLog(
        'asr_final | chars=${transcript.length} | '
        'preview="${_voicePipelineChainPreview(transcript, 120)}"',
      );

      if (cancelToken?.isCancelled ?? false) {
        await onUserCancel();
        return;
      }

      final textForTtsRaw = StreamController<String>();
      final textForTts =
          coalesceTtsText(textForTtsRaw.stream, ttsCoalescing).map((segment) {
        final t = segment.trim();
        if (t.isEmpty) {
          return segment;
        }
        _voicePipelineChainLog(
          'tts_text_segment | chars=${t.length} | speaker="${ttsOptions.voice}" | '
          'lang=${ttsOptions.languageCode} | '
          'preview="${_voicePipelineChainPreview(t, 80)}"',
        );
        return segment;
      });
      final ttsDone = Completer<void>();
      unawaited(() async {
        try {
          var audioChunkIx = 0;
          await for (final chunk in _ttsEngine.synthesizeStream(
            model: ttsModel,
            text: textForTts,
            options: ttsOptions,
          )) {
            if (cancelToken?.isCancelled ?? false) {
              break;
            }
            if (!chunk.isFinal && chunk.bytes.isNotEmpty) {
              _voicePipelineChainLog(
                'tts_audio_chunk | ix=$audioChunkIx | bytes=${chunk.bytes.length} | '
                'speaker="${ttsOptions.voice}"',
              );
              audioChunkIx++;
            }
            events.add(Voice2VoiceStreamEvent.ttsAudio(chunk));
          }
        } catch (error, stackTrace) {
          if (!ttsDone.isCompleted) {
            ttsDone.completeError(error, stackTrace);
          }
        } finally {
          if (!ttsDone.isCompleted) {
            ttsDone.complete();
          }
        }
      }());

      var emittedAssistantLength = 0;
      final prompt = _voicePrompt(
        transcript: transcript,
        instruction: instruction,
      );
      _voicePipelineChainLog(
        'llm_stream_start | model=${chatModel.manifest.id} | '
        'temperature=${chatParams.temperature} | topP=${chatParams.topP} | '
        'maxTokens=${chatParams.maxTokens}',
      );

      late final String assistantText;
      try {
        Future<String> runChat() {
          return _chatRunner.chatStream(
            model: chatModel,
            messages: [LocalChatMessage.user(prompt)],
            params: chatParams,
            toolRegistry: chatToolRegistry,
            onText: (partial) {
              if (cancelToken?.isCancelled ?? false) {
                return;
              }
              if (partial.length <= emittedAssistantLength) {
                return;
              }
              final delta = partial.substring(emittedAssistantLength);
              emittedAssistantLength = partial.length;
              textForTtsRaw.add(delta);
              events.add(Voice2VoiceStreamEvent.assistantDelta(delta));
            },
          );
        }

        if (cancelToken == null) {
          assistantText = await runChat();
        } else {
          assistantText = await Future.any<String>([
            runChat(),
            cancelToken.whenCancelled.then<String>(
              (_) => throw const VoicePipelineCancelled(),
            ),
          ]);
        }
      } on VoicePipelineCancelled {
        await textForTtsRaw.close();
        try {
          await ttsDone.future;
        } catch (_) {}
        await onUserCancel();
        return;
      }

      await textForTtsRaw.close();
      events.add(Voice2VoiceStreamEvent.assistantFinal(assistantText));

      _voicePipelineChainLog(
        'llm_final | assistant_chars=${assistantText.length} | '
        'preview="${_voicePipelineChainPreview(assistantText, 120)}"',
      );

      if (cancelToken != null) {
        try {
          await Future.any<void>([
            ttsDone.future,
            cancelToken.whenCancelled,
          ]);
        } catch (_) {}
        if (cancelToken.isCancelled) {
          await onUserCancel();
          return;
        }
      } else {
        await ttsDone.future;
      }

      events.add(const Voice2VoiceStreamEvent.done());
      _voicePipelineChainLog(
        'pipeline_done | speaker="${ttsOptions.voice}"',
      );
    } catch (error, stackTrace) {
      _voicePipelineChainLog('error | $error');
      events.addError(error, stackTrace);
    } finally {
      await events.close();
    }
  }
}

String _voicePrompt({required String transcript, required String instruction}) {
  final trimmedInstruction = instruction.trim();
  return '$transcript\n\nInstruction: ${trimmedInstruction.isEmpty ? 'Answer in the same language as the user. Keep the response concise.' : trimmedInstruction}';
}

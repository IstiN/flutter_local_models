import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:local_models_core/local_models_core.dart';
import 'package:local_models_sdk/local_models_sdk.dart' as sdk;
import 'package:path/path.dart' as p;

import 'studio_services.dart';

/// Converts Studio's [InstalledModel] to the SDK struct (same fields).
sdk.InstalledModel installedModelToSdk(InstalledModel model) {
  return sdk.InstalledModel(
    manifest: model.manifest,
    directory: model.directory,
    sourceLabel: model.sourceLabel,
    installedAt: model.installedAt,
    sizeBytes: model.sizeBytes,
    metadataUpdatedAt: model.metadataUpdatedAt,
  );
}

InstalledModel installedModelFromSdk(sdk.InstalledModel model) {
  return InstalledModel(
    manifest: model.manifest,
    directory: model.directory,
    sourceLabel: model.sourceLabel,
    installedAt: model.installedAt,
    sizeBytes: model.sizeBytes,
    metadataUpdatedAt: model.metadataUpdatedAt,
  );
}

/// Adapts [LocalChatRunner] to the SDK streaming pipeline.
final class StudioStreamingChatRunnerAdapter implements sdk.StreamingChatRunner {
  StudioStreamingChatRunnerAdapter(this._inner);

  final LocalChatRunner _inner;

  @override
  Future<String> chatStream({
    required sdk.InstalledModel model,
    required List<LocalChatMessage> messages,
    required void Function(String text) onText,
    LocalChatParams params = const LocalChatParams(),
    sdk.LmToolRegistry? toolRegistry,
  }) {
    return _inner.chatStream(
      model: installedModelFromSdk(model),
      messages: messages,
      onText: onText,
      params: params,
      toolRegistry: toolRegistry,
    );
  }
}

/// Uses a fixed recording path; drains [userAudio] and runs batch ASR once.
final class StudioFileStreamingAsrEngine implements sdk.StreamingAsrEngine {
  StudioFileStreamingAsrEngine({
    required this.audioRunner,
    required this.audioFilePath,
  });

  final LocalAudioRunner audioRunner;
  final String audioFilePath;

  @override
  Stream<sdk.StreamingAsrTranscript> transcribeStream({
    required sdk.InstalledModel model,
    required Stream<sdk.VoiceAudioChunk> audio,
    String? language,
  }) async* {
    debugPrint(
      '[VoiceUX:chain] asr_engine_begin | model=${model.manifest.id} | '
      'file=${p.basename(audioFilePath)} | lang=${language ?? 'default'}',
    );
    await audio.drain<void>();
    final text = await audioRunner.transcribeAudio(
      model: installedModelFromSdk(model),
      audioPath: audioFilePath,
      language: language,
    );
    debugPrint(
      '[VoiceUX:chain] asr_engine_done | model=${model.manifest.id} | '
      'transcript_chars=${text.length}',
    );
    yield sdk.StreamingAsrTranscript(text: text, isFinal: true);
  }
}

/// Maps LLM text segments to local or HTTP streaming TTS via [LocalAudioRunner].
///
/// [speech] must reflect the current Studio UI (OpenAI streaming endpoint, voice,
/// clone fields, etc.). The SDK [VoiceSynthesisOptions] on [synthesizeStream] is
/// unused so the host can pass a placeholder.
final class StudioLocalStreamingTtsEngine implements sdk.StreamingTtsEngine {
  StudioLocalStreamingTtsEngine(this._runner, this.speech);

  final LocalAudioRunner _runner;
  final SpeechSynthesisOptions speech;

  @override
  Stream<sdk.VoiceAudioChunk> synthesizeStream({
    required sdk.InstalledModel model,
    required Stream<String> text,
    sdk.VoiceSynthesisOptions options = const sdk.VoiceSynthesisOptions(),
  }) async* {
    options; // Host supplies UI options via [speech].
    final studioModel = installedModelFromSdk(model);
    var callIdx = 0;

    await for (final segment in text) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      debugPrint(
        '[VoiceUX:chain] tts_synthesize_stream | call=#${callIdx++} | '
        'model=${studioModel.manifest.id} | speaker="${speech.voice}" | '
        'lang=${speech.languageCode} | textChars=${trimmed.length}',
      );
      if (speech.streamSpeech &&
          speech.openAiCompatibleSpeechEndpoint != null) {
        await for (final chunk in _runner.synthesizeSpeechStream(
          model: studioModel,
          text: trimmed,
          options: speech,
        )) {
          yield sdk.VoiceAudioChunk(
            bytes: chunk.bytes,
            isFinal: chunk.isFinal,
            mediaType: chunk.mediaType,
          );
        }
      } else {
        final file = await _runner.synthesizeSpeech(
          model: studioModel,
          text: trimmed,
          options: speech,
        );
        final bytes = await file.readAsBytes();
        final ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
        yield sdk.VoiceAudioChunk(
          bytes: bytes,
          mediaType: _mimeForExt(ext),
        );
      }
    }
    yield sdk.VoiceAudioChunk(bytes: Uint8List(0), isFinal: true);
  }
}

String? _mimeForExt(String ext) {
  switch (ext.toLowerCase()) {
    case 'wav':
      return 'audio/wav';
    case 'mp3':
      return 'audio/mpeg';
    case 'opus':
      return 'audio/opus';
    case 'm4a':
    case 'aac':
      return 'audio/mp4';
    default:
      return null;
  }
}

/// One-shot audio stream for a recorded file (push-to-talk).
Stream<sdk.VoiceAudioChunk> voiceFileChunkStream(String path) async* {
  final bytes = await File(path).readAsBytes();
  if (bytes.isNotEmpty) {
    yield sdk.VoiceAudioChunk(bytes: bytes);
  }
  yield sdk.VoiceAudioChunk(bytes: Uint8List(0), isFinal: true);
}

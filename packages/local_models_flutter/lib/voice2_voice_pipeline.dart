import 'dart:typed_data';

import 'package:local_models_core/local_models_core.dart';

import 'studio_services.dart';

/// Result of a full voice → voice pass (ASR + chat + TTS).
class Voice2VoiceResult {
  const Voice2VoiceResult({
    required this.transcript,
    required this.assistantText,
    required this.synthesizedAudio,
    this.audioMediaType,
  });

  final String transcript;
  final String assistantText;
  final Uint8List synthesizedAudio;
  final String? audioMediaType;
}

typedef Voice2VoiceChat = Future<String> Function(
  String voicePrompt,
  void Function(String partial) onPartial,
);

typedef Voice2VoiceTtsStream = Stream<TtsAudioChunk> Function(
  String assistantText,
);

/// Injected pipeline (use in tests or custom hosts). Production code calls
/// [Voice2VoicePipeline.run] which delegates here.
Future<Voice2VoiceResult> runVoice2VoicePipelineInjected({
  required String instruction,
  required Future<String> Function() transcribe,
  required Voice2VoiceChat generateChat,
  required Voice2VoiceTtsStream synthesizeSpeech,
  void Function(String transcript)? onTranscript,
  void Function(String partialText, bool done)? onAssistantText,
  void Function(TtsAudioChunk chunk)? onTtsChunk,
}) async {
  final transcript = await transcribe();
  onTranscript?.call(transcript);

  final trimmedInstruction = instruction.trim();
  final voicePrompt =
      '$transcript\n\nInstruction: ${trimmedInstruction.isEmpty ? 'Answer in the same language as the user. Keep the response concise.' : trimmedInstruction}';

  final response = await generateChat(
    voicePrompt,
    (partial) => onAssistantText?.call(partial, false),
  );
  onAssistantText?.call(response, true);

  final buffer = BytesBuffer();
  String? mediaType;
  await for (final chunk in synthesizeSpeech(response)) {
    onTtsChunk?.call(chunk);
    mediaType ??= chunk.mediaType;
    if (!chunk.isFinal && chunk.bytes.isNotEmpty) {
      buffer.add(chunk.bytes);
    }
  }

  return Voice2VoiceResult(
    transcript: transcript,
    assistantText: response,
    synthesizedAudio: buffer.takeBytes(),
    audioMediaType: mediaType,
  );
}

/// Local ASR → LLM (streaming text) → TTS (optionally streaming HTTP) pipeline.
class Voice2VoicePipeline {
  const Voice2VoicePipeline._();

  static Future<Voice2VoiceResult> run({
    required LocalAudioRunner audioRunner,
    required LocalChatRunner chatRunner,
    required InstalledModel asrModel,
    required InstalledModel chatModel,
    required InstalledModel ttsModel,
    required String userAudioPath,
    String instruction = '',
    LocalChatParams chatParams = const LocalChatParams(),
    SpeechSynthesisOptions ttsOptions = const SpeechSynthesisOptions(),
    String? asrLanguage,
    void Function(String transcript)? onTranscript,
    void Function(String partialText, bool done)? onAssistantText,
    void Function(TtsAudioChunk chunk)? onTtsChunk,
  }) {
    return runVoice2VoicePipelineInjected(
      instruction: instruction,
      transcribe: () => audioRunner.transcribeAudio(
        model: asrModel,
        audioPath: userAudioPath,
        language: asrLanguage,
      ),
      generateChat: (prompt, onPartial) => chatRunner.chatStream(
        model: chatModel,
        messages: [LocalChatMessage.user(prompt)],
        params: chatParams,
        onText: onPartial,
      ),
      synthesizeSpeech: (text) => audioRunner.synthesizeSpeechStream(
        model: ttsModel,
        text: text,
        options: ttsOptions,
      ),
      onTranscript: onTranscript,
      onAssistantText: onAssistantText,
      onTtsChunk: onTtsChunk,
    );
  }
}

/// Growable byte accumulator (kept private to this library).
class BytesBuffer {
  final List<int> _data = <int>[];

  void add(Uint8List chunk) {
    _data.addAll(chunk);
  }

  Uint8List takeBytes() => Uint8List.fromList(_data);
}

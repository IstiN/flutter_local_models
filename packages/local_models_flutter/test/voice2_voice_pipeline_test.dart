import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_models_flutter/local_models_flutter.dart';

void main() {
  test('runVoice2VoicePipelineInjected wires transcript, chat, tts', () async {
    final partials = <String>[];
    final dones = <bool>[];
    final ttsChunks = <TtsAudioChunk>[];

    final result = await runVoice2VoicePipelineInjected(
      instruction: 'Say hi',
      transcribe: () async => 'user said this',
      generateChat: (prompt, onPartial) async {
        expect(prompt, contains('user said this'));
        expect(prompt, contains('Instruction: Say hi'));
        onPartial('partial');
        partials.add('partial');
        onPartial('full text');
        partials.add('full text');
        return 'assistant final';
      },
      synthesizeSpeech: (text) async* {
        expect(text, 'assistant final');
        yield TtsAudioChunk(
          bytes: Uint8List.fromList([10, 20]),
          isFinal: false,
          mediaType: 'audio/wav',
        );
        yield TtsAudioChunk(bytes: Uint8List(0), isFinal: true);
      },
      onAssistantText: (t, d) {
        dones.add(d);
      },
      onTtsChunk: ttsChunks.add,
    );

    expect(result.transcript, 'user said this');
    expect(result.assistantText, 'assistant final');
    expect(result.synthesizedAudio, Uint8List.fromList([10, 20]));
    expect(result.audioMediaType, 'audio/wav');
    expect(partials, ['partial', 'full text']);
    expect(dones, [false, false, true]);
    expect(ttsChunks.length, 2);
  });

  test('runVoice2VoicePipelineInjected uses default instruction clause',
      () async {
    String? capturedPrompt;
    await runVoice2VoicePipelineInjected(
      instruction: '',
      transcribe: () async => 'x',
      generateChat: (prompt, onPartial) async {
        capturedPrompt = prompt;
        return 'ok';
      },
      synthesizeSpeech: (_) async* {
        yield TtsAudioChunk(bytes: Uint8List(0), isFinal: true);
      },
    );
    expect(capturedPrompt, contains('Answer in the same language'));
  });
}

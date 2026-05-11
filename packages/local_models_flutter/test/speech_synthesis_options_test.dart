import 'package:flutter_test/flutter_test.dart';
import 'package:local_models_flutter/local_models_flutter.dart';

void main() {
  test('SpeechSynthesisOptions.copyWith keeps unspecified fields', () {
    const base = SpeechSynthesisOptions(
      voice: 'Ryan',
      instruct: 'calm',
      speechResponseFormat: 'wav',
      streamSpeech: true,
    );
    final next = base.copyWith(voice: 'Eric', streamSpeech: false);
    expect(next.voice, 'Eric');
    expect(next.instruct, 'calm');
    expect(next.speechResponseFormat, 'wav');
    expect(next.streamSpeech, isFalse);
  });

  test('SpeechSynthesisOptions streaming fields default off', () {
    const o = SpeechSynthesisOptions();
    expect(o.openAiCompatibleSpeechEndpoint, isNull);
    expect(o.streamSpeech, isFalse);
    expect(o.speechResponseFormat, 'opus');
  });
}

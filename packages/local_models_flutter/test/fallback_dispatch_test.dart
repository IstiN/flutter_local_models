import 'package:flutter_test/flutter_test.dart';
import 'package:local_models_flutter/local_models_flutter.dart';

void main() {
  test('FallbackFlmDispatcher retries audio ops on primary failure', () {
    final primary = RecordingFlmDispatcher()
      ..onInvoke = (op, _) {
        if (op == 'audio.transcribe') {
          return <String, Object?>{'ok': false, 'error': 'not implemented in Swift'};
        }
        return <String, Object?>{'ok': true, 'text': 'from primary'};
      };

    final fallback = RecordingFlmDispatcher()
      ..onInvoke = (op, _) {
        expect(op, 'audio.transcribe');
        return <String, Object?>{'ok': true, 'text': 'from python'};
      };

    final chain = FallbackFlmDispatcher(primary: primary, fallback: fallback);
    final r = chain.invoke('audio.transcribe', <String, Object?>{
      'modelPath': '/m',
      'audioPath': '/a.wav',
    });

    expect(r['ok'], true);
    expect(r['text'], 'from python');
    expect(primary.calls, hasLength(1));
    expect(fallback.calls, hasLength(1));
  });

  test('FallbackFlmDispatcher does not retry lm.generate', () {
    final primary = RecordingFlmDispatcher()
      ..onInvoke = (op, _) {
        return <String, Object?>{'ok': false, 'error': 'fail lm'};
      };

    final fallback = RecordingFlmDispatcher()
      ..onInvoke = (op, _) {
        return <String, Object?>{'ok': true, 'text': 'should not'};
      };

    final chain = FallbackFlmDispatcher(primary: primary, fallback: fallback);
    final r = chain.invoke('lm.generate', <String, Object?>{});

    expect(r['ok'], false);
    expect(fallback.calls, isEmpty);
  });
}

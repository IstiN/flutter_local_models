import 'dart:io';

import 'package:local_models_flutter/local_models_flutter.dart';

import '../fixtures/minimal_wav.dart';

/// Simulates a tiny ASR model, tiny LM, and tiny TTS over the JSON FFI contract.
///
/// Use with [NativeAudioEngine] / [NativeLmEngine] to run full-stack voice E2E
/// tests without downloading weights.
final class E2eTinyMlxDispatcher implements FlmDispatching {
  E2eTinyMlxDispatcher({
    this.transcript = 'user said e2e phrase',
    this.assistantReply = 'assistant e2e reply',
  });

  @override
  bool get isBlockingInvoke => false;

  final String transcript;
  final String assistantReply;

  final List<({String op, Map<String, Object?> payload})> calls =
      <({String op, Map<String, Object?> payload})>[];

  @override
  Map<String, Object?> invoke(String operation, Map<String, Object?> payload) {
    calls.add((op: operation, payload: Map<String, Object?>.from(payload)));
    switch (operation) {
      case 'audio.transcribe':
        final path = payload['audioPath'] as String?;
        if (path == null || path.isEmpty) {
          return {'ok': false, 'error': 'missing audioPath'};
        }
        if (!File(path).existsSync()) {
          return {'ok': false, 'error': 'audio file missing: $path'};
        }
        return {'ok': true, 'text': transcript};

      case 'lm.generate':
        return {'ok': true, 'text': assistantReply};

      case 'audio.synthesize':
        final text = payload['text'] as String?;
        if (text == null || text.isEmpty) {
          return {'ok': false, 'error': 'missing text for TTS'};
        }
        final outDir = Directory.systemTemp.createTempSync('flm-e2e-tts-');
        final outFile = File('${outDir.path}/synth.wav');
        outFile.writeAsBytesSync(minimalWavMono16k());
        return {'ok': true, 'outputAudioPath': outFile.path};

      case 'image.generate':
        return {'ok': false, 'error': 'not used in voice e2e'};

      default:
        return {'ok': false, 'error': 'unknown op: $operation'};
    }
  }
}

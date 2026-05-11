import 'dart:convert';
import 'dart:io';

import 'native_dispatch.dart';

/// Calls open-source **Python** [MLX-Audio](https://github.com/Blaizzy/mlx-audio) CLIs
/// when the Swift bridge does not implement ASR/TTS.
///
/// Requires a working install, e.g. `pip install mlx-audio` and MLX on Apple Silicon.
/// Override interpreter with [pythonExecutable] or env `FLM_MLX_PYTHON`.
final class ProcessFlmDispatcher implements FlmDispatching {
  ProcessFlmDispatcher({String? pythonExecutable})
    : _python = pythonExecutable ?? _resolvePython();

  final String _python;

  static String _resolvePython() {
    final fromEnv = Platform.environment['FLM_MLX_PYTHON'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      return fromEnv.trim();
    }
    return 'python3';
  }

  @override
  Map<String, Object?> invoke(String operation, Map<String, Object?> payload) {
    switch (operation) {
      case 'audio.transcribe':
        return _transcribe(payload);
      case 'audio.synthesize':
        return _synthesize(payload);
      default:
        return <String, Object?>{
          'ok': false,
          'error':
              'ProcessFlmDispatcher only implements audio.* (got $operation). '
              'Use the native bridge for LM / image.',
        };
    }
  }

  Map<String, Object?> _transcribe(Map<String, Object?> payload) {
    final modelPath = payload['modelPath'] as String?;
    final audioPath = payload['audioPath'] as String?;
    if (modelPath == null || modelPath.isEmpty) {
      return {'ok': false, 'error': 'missing modelPath'};
    }
    if (audioPath == null || audioPath.isEmpty) {
      return {'ok': false, 'error': 'missing audioPath'};
    }
    if (!File(audioPath).existsSync()) {
      return {'ok': false, 'error': 'audio file missing: $audioPath'};
    }

    final outDir = Directory.systemTemp.createTempSync('flm-stt-');
    try {
      final args = <String>[
        '-m',
        'mlx_audio.stt.generate',
        '--model',
        modelPath,
        '--audio',
        audioPath,
        '--output-path',
        outDir.path,
        '--format',
        'txt',
      ];
      final lang = payload['language'] as String?;
      if (lang != null && lang.isNotEmpty && lang != 'auto') {
        args.addAll(['--language', lang]);
      }

      final result = Process.runSync(_python, args);
      if (result.exitCode != 0) {
        final err = (result.stderr as String).trim();
        final out = (result.stdout as String).trim();
        return {
          'ok': false,
          'error':
              'mlx_audio.stt.generate failed (exit ${result.exitCode}). '
              '${err.isEmpty ? out : err}',
        };
      }

      final textFile = _firstFileWithExtension(outDir, '.txt');
      if (textFile == null) {
        return {
          'ok': false,
          'error':
              'STT produced no .txt under ${outDir.path}. '
              'Is mlx-audio installed? ($_python -m mlx_audio.stt.generate --help)',
        };
      }
      final text = textFile.readAsStringSync().trim();
      if (text.isEmpty) {
        return {'ok': false, 'error': 'STT returned empty transcript'};
      }
      return {'ok': true, 'text': text};
    } catch (e, st) {
      return {
        'ok': false,
        'error': 'STT process error: $e\n$st',
      };
    }
  }

  Map<String, Object?> _synthesize(Map<String, Object?> payload) {
    final modelPath = payload['modelPath'] as String?;
    final text = payload['text'] as String?;
    if (modelPath == null || modelPath.isEmpty) {
      return {'ok': false, 'error': 'missing modelPath'};
    }
    if (text == null || text.isEmpty) {
      return {'ok': false, 'error': 'missing text'};
    }

    final outDir = Directory.systemTemp.createTempSync('flm-tts-');
    try {
      final args = <String>[
        '-m',
        'mlx_audio.tts.generate',
        '--model',
        modelPath,
        '--text',
        text,
        '--output_path',
        outDir.path,
      ];

      final voice = (payload['voice'] as String?)?.trim();
      if (voice != null && voice.isNotEmpty) {
        args.addAll(['--voice', voice]);
      }

      final joinAudio = payload['join_audio'];
      if (joinAudio == true) {
        args.add('--join_audio');
      }

      final lang = (payload['languageCode'] as String?)?.trim();
      if (lang != null && lang.isNotEmpty) {
        args.addAll(['--lang_code', lang]);
      }

      final refAudio = payload['referenceAudioPath'] as String?;
      final refText = payload['referenceText'] as String?;
      if (refAudio != null &&
          refAudio.isNotEmpty &&
          refText != null &&
          refText.isNotEmpty) {
        args.addAll(['--ref_audio', refAudio, '--ref_text', refText]);
      }

      final result = Process.runSync(_python, args);
      if (result.exitCode != 0) {
        final err = (result.stderr as String).trim();
        final out = (result.stdout as String).trim();
        return {
          'ok': false,
          'error':
              'mlx_audio.tts.generate failed (exit ${result.exitCode}). '
              '${err.isEmpty ? out : err}',
        };
      }

      final audioFile = _firstAudioFile(outDir);
      if (audioFile == null) {
        return {
          'ok': false,
          'error':
              'TTS wrote no audio under ${outDir.path}. '
              'Is mlx-audio installed? ($_python -m mlx_audio.tts.generate --help)',
        };
      }
      return {'ok': true, 'outputAudioPath': audioFile.path};
    } catch (e, st) {
      return {
        'ok': false,
        'error': 'TTS process error: $e\n$st',
      };
    }
  }
}

File? _firstFileWithExtension(Directory root, String extension) {
  if (!root.existsSync()) {
    return null;
  }
  final lower = extension.toLowerCase();
  for (final e in root.listSync(recursive: true)) {
    if (e is! File) {
      continue;
    }
    if (e.path.toLowerCase().endsWith(lower)) {
      return e;
    }
  }
  return null;
}

File? _firstAudioFile(Directory root) {
  const extensions = ['.wav', '.mp3', '.flac', '.ogg', '.m4a'];
  if (!root.existsSync()) {
    return null;
  }
  for (final e in root.listSync(recursive: true)) {
    if (e is! File) {
      continue;
    }
    final p = e.path.toLowerCase();
    for (final ext in extensions) {
      if (p.endsWith(ext)) {
        return e;
      }
    }
  }
  return null;
}

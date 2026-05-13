import 'dart:io';

import 'package:path/path.dart' as p;

import 'native_dispatch.dart';

/// Subprocess backends when the Swift bridge does not implement an operation:
/// **Python** [MLX-Audio](https://github.com/Blaizzy/mlx-audio) for ASR/TTS, and
/// `mflux-generate*` CLIs for `image.generate`.
///
/// MLX-Audio: `pip install mlx-audio` and MLX on Apple Silicon. Interpreter: [pythonExecutable]
/// or env `FLM_MLX_PYTHON`. Image: install mflux tools on `PATH` or set `FLM_MFLUX_GENERATE`.
final class ProcessFlmDispatcher implements FlmDispatching {
  ProcessFlmDispatcher({String? pythonExecutable})
    : _python = pythonExecutable ?? _resolvePython();

  final String _python;

  @override
  bool get isBlockingInvoke => true;

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
      case 'image.generate':
        return _generateImage(payload);
      default:
        return <String, Object?>{
          'ok': false,
          'error':
              'ProcessFlmDispatcher only implements audio.* and image.generate '
              '(got $operation). Use the native bridge for LM.',
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

      final instruct = (payload['instruct'] as String?)?.trim();
      if (instruct != null && instruct.isNotEmpty) {
        args.addAll(['--instruct', instruct]);
      }

      final joinAudio = payload['join_audio'];
      if (joinAudio == true) {
        args.add('--join_audio');
      }

      final lang = (payload['languageCode'] as String?)?.trim();
      if (lang != null && lang.isNotEmpty) {
        args.addAll(['--lang_code', lang]);
      }

      final speed = payload['speed'];
      if (speed != null) {
        final speedStr = speed.toString().trim();
        if (speedStr.isNotEmpty && speedStr != '1.0' && speedStr != '1') {
          args.addAll(['--speed', speedStr]);
        }
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

  Map<String, Object?> _generateImage(Map<String, Object?> payload) {
    final modelPath = payload['modelPath'] as String?;
    final prompt = payload['prompt'] as String?;
    if (modelPath == null || modelPath.isEmpty) {
      return {'ok': false, 'error': 'missing modelPath'};
    }
    if (prompt == null || prompt.isEmpty) {
      return {'ok': false, 'error': 'missing prompt'};
    }
    final modelDir = Directory(modelPath);
    if (!modelDir.existsSync()) {
      return {'ok': false, 'error': 'model directory missing: $modelPath'};
    }

    final defaults = _asObjectMap(payload['defaults']);
    final extra = _asObjectMap(payload['extra']);
    final manifestId = (payload['manifestId'] as String?)?.trim() ?? '';
    final displayName = (payload['displayName'] as String?)?.trim() ?? '';

    final width = _intFromMap(defaults, 'width') ?? 512;
    final height = _intFromMap(defaults, 'height') ?? 512;
    final steps = _intFromMap(defaults, 'steps') ?? 4;
    final guidance = _doubleFromMap(defaults, 'guidance');
    final seed = _intFromMap(defaults, 'seed');

    final exe = _resolveMfluxGenerateExecutable(
      extra,
      modelPath,
      manifestId,
      displayName,
    );
    final baseModel = (extra?['mflux_base_model'] as String?)?.trim();

    final outDir = Directory.systemTemp.createTempSync('flm-mflux-');
    final outFile = File(p.join(outDir.path, 'out.png'));

    final args = <String>[
      '--model',
      modelPath,
      if (baseModel != null && baseModel.isNotEmpty) ...[
        '--base-model',
        baseModel,
      ],
      '--prompt',
      prompt,
      '--output',
      outFile.path,
      '--width',
      '$width',
      '--height',
      '$height',
      '--steps',
      '$steps',
    ];
    if (guidance != null) {
      args.addAll(['--guidance', '$guidance']);
    }
    if (seed != null) {
      args.addAll(['--seed', '$seed']);
    }

    try {
      final result = Process.runSync(exe, args);
      if (result.exitCode != 0) {
        final err = (result.stderr as String).trim();
        final out = (result.stdout as String).trim();
        return {
          'ok': false,
          'error':
              'mflux generate failed (exit ${result.exitCode}). '
              '${err.isEmpty ? out : err}. '
              'Install mflux (e.g. mflux-generate on PATH) or set FLM_MFLUX_GENERATE.',
        };
      }
      if (outFile.existsSync()) {
        return {'ok': true, 'outputImagePath': outFile.path};
      }
      final produced = _firstImageFile(outDir);
      if (produced != null) {
        return {'ok': true, 'outputImagePath': produced.path};
      }
      return {
        'ok': false,
        'error': 'mflux produced no image under ${outDir.path}',
      };
    } catch (e, st) {
      return {
        'ok': false,
        'error': 'mflux process error: $e\n$st',
      };
    }
  }
}

Map<String, Object?>? _asObjectMap(Object? raw) {
  if (raw == null) {
    return null;
  }
  if (raw is Map<String, Object?>) {
    return raw;
  }
  if (raw is Map) {
    return raw.map((k, v) => MapEntry('$k', v));
  }
  return null;
}

int? _intFromMap(Map<String, Object?>? m, String key) {
  if (m == null) {
    return null;
  }
  final v = m[key];
  if (v is int) {
    return v;
  }
  if (v is num) {
    return v.round();
  }
  if (v is String) {
    return int.tryParse(v);
  }
  return null;
}

double? _doubleFromMap(Map<String, Object?>? m, String key) {
  if (m == null) {
    return null;
  }
  final v = m[key];
  if (v is double) {
    return v;
  }
  if (v is num) {
    return v.toDouble();
  }
  if (v is String) {
    return double.tryParse(v);
  }
  return null;
}

List<String> _pathEnvDirectories() {
  final sep = Platform.isWindows ? ';' : ':';
  final raw = Platform.environment['PATH'] ?? '';
  return raw.split(sep).where((e) => e.trim().isNotEmpty).toList();
}

String? _which(String command) {
  if (command.contains('/')) {
    return File(command).existsSync() ? command : null;
  }
  for (final dir in _pathEnvDirectories()) {
    final full = p.join(dir, command);
    if (File(full).existsSync()) {
      return full;
    }
  }
  return null;
}

String _resolveMfluxGenerateExecutable(
  Map<String, Object?>? extra,
  String modelPath,
  String manifestId,
  String displayName,
) {
  final fromEnv = Platform.environment['FLM_MFLUX_GENERATE']?.trim();
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return fromEnv;
  }

  final extraMap = extra ?? const <String, Object?>{};
  final runner = (extraMap['mflux_runner'] as String?)?.trim() ?? '';
  final baseName = p.basename(modelPath);
  final identity = '$runner $manifestId $displayName $baseName'.toLowerCase();

  final String commandName;
  if (identity.contains('qwen')) {
    commandName = 'mflux-generate-qwen';
  } else if (identity.contains('z-image-turbo')) {
    commandName = 'mflux-generate-z-image-turbo';
  } else if (identity.contains('z-image')) {
    commandName = 'mflux-generate-z-image';
  } else {
    commandName = 'mflux-generate';
  }

  final found = _which(commandName);
  if (found != null) {
    return found;
  }
  final home = Platform.environment['HOME']?.trim();
  if (home != null && home.isNotEmpty) {
    return p.join(home, '.local', 'bin', commandName);
  }
  return commandName;
}

File? _firstImageFile(Directory root) {
  const extensions = ['.png', '.jpg', '.jpeg', '.webp'];
  if (!root.existsSync()) {
    return null;
  }
  for (final e in root.listSync(recursive: true)) {
    if (e is! File) {
      continue;
    }
    final pathLower = e.path.toLowerCase();
    for (final ext in extensions) {
      if (pathLower.endsWith(ext)) {
        return e;
      }
    }
  }
  return null;
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

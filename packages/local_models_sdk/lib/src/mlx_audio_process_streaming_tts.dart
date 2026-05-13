import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'model_store.dart';
import 'voice2voice_streaming.dart';

/// Resolves `packages/local_models_sdk/tool/mlx_audio_streaming_tts_worker.py`
/// when [VoiceSynthesisOptions.workerScriptPath] is null.
///
/// Search order:
/// - [VoiceSynthesisOptions.workerScriptPath]
/// - `FLM_MLX_TTS_WORKER` env (absolute path)
/// - Walk up from [Directory.current] until `packages/local_models_sdk/tool/...` exists
String resolveMlxAudioStreamingTtsWorkerScript({
  String? workerScriptPath,
  String? startDirectory,
}) {
  final fromOpt = workerScriptPath?.trim();
  if (fromOpt != null && fromOpt.isNotEmpty) {
    return fromOpt;
  }
  final fromEnv = Platform.environment['FLM_MLX_TTS_WORKER']?.trim();
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return fromEnv;
  }
  var dir = Directory(startDirectory ?? Directory.current.path);
  for (var i = 0; i < 12; i++) {
    final candidate = File(
      p.join(
        dir.path,
        'packages',
        'local_models_sdk',
        'tool',
        'mlx_audio_streaming_tts_worker.py',
      ),
    );
    if (candidate.existsSync()) {
      return candidate.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  throw StateError(
    'Could not find mlx_audio_streaming_tts_worker.py. '
    'Run from repo root, set FLM_MLX_TTS_WORKER, or pass workerScriptPath.',
  );
}

String _resolvePythonExecutable(VoiceSynthesisOptions options) {
  final fromOpt = options.pythonExecutable?.trim();
  if (fromOpt != null && fromOpt.isNotEmpty) {
    return fromOpt;
  }
  final fromEnv = Platform.environment['FLM_MLX_PYTHON']?.trim();
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return fromEnv;
  }
  return 'python3';
}

/// Streams WAV chunks from a long-lived `mlx_audio` process (see
/// `tool/mlx_audio_streaming_tts_worker.py`).
final class MlxAudioProcessStreamingTtsEngine implements StreamingTtsEngine {
  MlxAudioProcessStreamingTtsEngine({
    String? workerScriptPath,
    String? startDirectory,
  }) : _workerScriptPath = workerScriptPath,
       _startDirectory = startDirectory;

  final String? _workerScriptPath;
  final String? _startDirectory;

  @override
  Stream<VoiceAudioChunk> synthesizeStream({
    required InstalledModel model,
    required Stream<String> text,
    VoiceSynthesisOptions options = const VoiceSynthesisOptions(),
  }) {
    final controller = StreamController<VoiceAudioChunk>();
    unawaited(_run(model, text, options, controller));
    return controller.stream;
  }

  Future<void> _run(
    InstalledModel model,
    Stream<String> text,
    VoiceSynthesisOptions options,
    StreamController<VoiceAudioChunk> controller,
  ) async {
    Process? process;
    try {
      final script = resolveMlxAudioStreamingTtsWorkerScript(
        workerScriptPath: _workerScriptPath ?? options.workerScriptPath,
        startDirectory: _startDirectory,
      );
      final python = _resolvePythonExecutable(options);
      process = await Process.start(python, [script], runInShell: false);
      unawaited(process.stderr.drain<void>());

      var langCode = options.languageCode.trim();
      if (langCode.isEmpty || langCode == 'auto') {
        langCode = 'english';
      }

      final cfg = <String, Object?>{
        'model_path': model.directory.path,
        'voice': options.voice,
        'lang_code': langCode,
        'speed': options.speed ?? 1.0,
        'streaming_interval': options.streamingInterval ?? 0.35,
        'temperature': options.temperature ?? 0.7,
        'verbose': options.workerVerbose,
        'max_tokens': options.maxTokens ?? 1200,
        if (options.instruct != null && options.instruct!.trim().isNotEmpty)
          'instruct': options.instruct!.trim(),
        if (options.referenceAudioPath != null &&
            options.referenceAudioPath!.trim().isNotEmpty &&
            options.referenceText != null &&
            options.referenceText!.trim().isNotEmpty) ...{
          'ref_audio': options.referenceAudioPath!.trim(),
          'ref_text': options.referenceText!.trim(),
        },
      };
      process.stdin.writeln(jsonEncode(cfg));

      Future<void> feedStdin() async {
        try {
          await for (final segment in text) {
            final trimmed = segment.trim();
            if (trimmed.isEmpty) {
              continue;
            }
            process!.stdin.writeln(
              jsonEncode(<String, Object?>{'text': trimmed}),
            );
          }
        } finally {
          await process?.stdin.close();
        }
      }

      final feedFuture = feedStdin();

      await for (final line in process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        final decoded = jsonDecode(trimmed);
        if (decoded is! Map) {
          continue;
        }
        final map = Map<String, Object?>.from(decoded);
        if (map['error'] != null) {
          throw StateError(map['error'].toString());
        }
        if (map['done'] == true) {
          break;
        }
        final path = map['wav'] as String?;
        if (path == null || path.isEmpty) {
          continue;
        }
        final file = File(path);
        final bytes = await file.readAsBytes();
        try {
          if (file.existsSync()) {
            await file.delete();
          }
        } on FileSystemException {
          // Best-effort cleanup of temp wav from worker.
        }
        final sr = map['sample_rate'];
        controller.add(
          VoiceAudioChunk(
            bytes: bytes,
            mediaType: 'audio/wav',
            sampleRate: sr is int ? sr : int.tryParse('$sr'),
          ),
        );
      }

      await feedFuture;
      final code = await process.exitCode;
      if (code != 0) {
        throw StateError('mlx_audio TTS worker exited with code $code');
      }
      controller.add(VoiceAudioChunk(bytes: Uint8List(0), isFinal: true));
    } catch (error, stackTrace) {
      if (!controller.isClosed) {
        controller.addError(error, stackTrace);
      }
    } finally {
      await controller.close();
    }
  }
}

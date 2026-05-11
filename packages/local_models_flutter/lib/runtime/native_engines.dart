import 'dart:convert';
import 'dart:io';

import 'package:local_models_core/local_models_core.dart';

import 'native_dispatch.dart';

class LmCompletionRequest {
  const LmCompletionRequest({
    required this.modelPath,
    required this.manifest,
    required this.prompt,
    this.audioPath,
    this.imagePath,
    this.maxTokens = 256,
    this.temperature,
    this.topP,
    this.enableThinking,
  });

  final String modelPath;
  final LocalModelManifest manifest;
  final String prompt;
  final String? audioPath;
  final String? imagePath;
  final int maxTokens;
  final double? temperature;
  final double? topP;
  final bool? enableThinking;
}

abstract class LmEngine {
  Future<String> complete(LmCompletionRequest request);
}

bool manifestSupportsTextPrompt(LocalModelManifest manifest) {
  final isLm =
      manifest.tasks.contains(ModelTask.chat) &&
      manifest.runtimeAdapter == RuntimeAdapter.mlxLm;
  final isVlm =
      manifest.tasks.contains(ModelTask.chat) &&
      manifest.runtimeAdapter == RuntimeAdapter.mlxVlm;
  return isLm || isVlm;
}

final class NativeLmEngine implements LmEngine {
  NativeLmEngine({FlmDispatching? dispatch})
    : _dispatch = dispatch ?? FlmNativeDispatcher();

  final FlmDispatching _dispatch;

  @override
  Future<String> complete(LmCompletionRequest request) async {
    if (!manifestSupportsTextPrompt(request.manifest)) {
      throw StateError(
        'Chat verification currently supports installed mlx_lm and mlx_vlm chat models.',
      );
    }
    final payload = <String, Object?>{
      'modelPath': request.modelPath,
      'runtimeAdapter': runtimeAdapterWireName(request.manifest.runtimeAdapter),
      'prompt': request.prompt,
      'maxTokens': request.maxTokens,
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.topP != null) 'topP': request.topP,
      if (request.enableThinking != null)
        'enableThinking': request.enableThinking,
      if (request.audioPath != null) 'audioPath': request.audioPath,
      if (request.imagePath != null) 'imagePath': request.imagePath,
    };
    final map = _dispatch.invoke('lm.generate', payload);
    if (map['ok'] == true) {
      final text = map['text'];
      if (text is! String || text.trim().isEmpty) {
        throw StateError('Native LM returned empty text');
      }
      return text;
    }
    throw StateError(map['error'] as String? ?? jsonEncode(map));
  }
}

abstract class AudioEngine {
  Future<String> transcribe({
    required String modelPath,
    required LocalModelManifest manifest,
    required String audioPath,
    String? language,
  });

  /// [synthesizeFields] is a flat map: voice, instruct, lang_code, ref paths, speed,
  /// merged runtime defaults — built by the caller.
  Future<File> synthesizeToFile({
    required String modelPath,
    required LocalModelManifest manifest,
    required String text,
    required Map<String, Object?> synthesizeFields,
  });
}

bool manifestSupportsSpeechToText(LocalModelManifest manifest) {
  return manifest.tasks.contains(ModelTask.speechToText) &&
      manifest.runtimeAdapter == RuntimeAdapter.mlxAudio;
}

bool manifestSupportsTts(LocalModelManifest manifest) {
  return manifest.tasks.contains(ModelTask.textToSpeech) &&
      manifest.runtimeAdapter == RuntimeAdapter.mlxAudio;
}

final class NativeAudioEngine implements AudioEngine {
  NativeAudioEngine({FlmDispatching? dispatch})
    : _dispatch = dispatch ?? FlmNativeDispatcher();

  final FlmDispatching _dispatch;

  @override
  Future<String> transcribe({
    required String modelPath,
    required LocalModelManifest manifest,
    required String audioPath,
    String? language,
  }) async {
    if (!manifestSupportsSpeechToText(manifest)) {
      throw StateError(
        'Speech-to-text supports installed mlx_audio models only.',
      );
    }
    final map = _dispatch.invoke('audio.transcribe', <String, Object?>{
      'modelPath': modelPath,
      'audioPath': audioPath,
      if (language != null && language.trim().isNotEmpty)
        'language': language.trim(),
    });
    if (map['ok'] == true) {
      final text = map['text'];
      if (text is! String || text.trim().isEmpty) {
        throw StateError('Native ASR returned empty text');
      }
      return text.trim();
    }
    throw StateError(map['error'] as String? ?? jsonEncode(map));
  }

  @override
  Future<File> synthesizeToFile({
    required String modelPath,
    required LocalModelManifest manifest,
    required String text,
    required Map<String, Object?> synthesizeFields,
  }) async {
    if (!manifestSupportsTts(manifest)) {
      throw StateError(
        'Speech synthesis supports installed mlx_audio TTS models only.',
      );
    }
    final payload = <String, Object?>{
      'modelPath': modelPath,
      'manifestId': manifest.id,
      'text': text,
      ...synthesizeFields,
    };
    final map = _dispatch.invoke('audio.synthesize', payload);
    if (map['ok'] == true) {
      final path = map['outputAudioPath'] as String?;
      if (path == null || path.isEmpty) {
        throw StateError('Native TTS did not return outputAudioPath');
      }
      final file = File(path);
      if (!file.existsSync()) {
        throw StateError('Native TTS path missing: $path');
      }
      return file;
    }
    throw StateError(map['error'] as String? ?? jsonEncode(map));
  }
}

abstract class ImageEngine {
  Future<File> generate({
    required String modelPath,
    required LocalModelManifest manifest,
    required String prompt,
    void Function(double progress)? onProgress,
  });
}

bool manifestSupportsImageGen(LocalModelManifest manifest) {
  return manifest.tasks.contains(ModelTask.imageGeneration) &&
      manifest.runtimeAdapter == RuntimeAdapter.mflux;
}

final class NativeImageEngine implements ImageEngine {
  NativeImageEngine({FlmDispatching? dispatch})
    : _dispatch = dispatch ?? FlmNativeDispatcher();

  final FlmDispatching _dispatch;

  @override
  Future<File> generate({
    required String modelPath,
    required LocalModelManifest manifest,
    required String prompt,
    void Function(double progress)? onProgress,
  }) async {
    if (!manifestSupportsImageGen(manifest)) {
      throw StateError(
        'Image generation supports mflux-class models via native runtime.',
      );
    }
    final defaults = manifest.runtimeConfig.defaultParameters;
    final extra = manifest.runtimeConfig.extra;
    final map = _dispatch.invoke('image.generate', <String, Object?>{
      'modelPath': modelPath,
      'prompt': prompt,
      'defaults': defaults,
      'extra': extra,
    });
    if (map['ok'] == true) {
      final path = map['outputImagePath'] as String?;
      if (path == null || path.isEmpty) {
        throw StateError('Native image gen did not return outputImagePath');
      }
      onProgress?.call(1);
      final file = File(path);
      if (!file.existsSync()) {
        throw StateError('Native image path missing: $path');
      }
      return file;
    }
    throw StateError(map['error'] as String? ?? jsonEncode(map));
  }
}

LmEngine defaultLmEngine() => NativeLmEngine();

AudioEngine defaultAudioEngine() => NativeAudioEngine();

ImageEngine defaultImageEngine() => NativeImageEngine();

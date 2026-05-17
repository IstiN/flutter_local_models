import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:local_models_core/local_models_core.dart';

import 'fallback_dispatch.dart';
import 'native_dispatch.dart';
import 'runtime_policy.dart';

Map<String, Object?> _jsonMapFromDynamic(Object? value) {
  if (value == null || value is! Map) {
    return const <String, Object?>{};
  }
  return Map<String, Object?>.from(
    value.map((k, v) => MapEntry('$k', _jsonValueFromDynamic(v))),
  );
}

Object? _jsonValueFromDynamic(Object? value) {
  if (value == null || value is num || value is String || value is bool) {
    return value;
  }
  if (value is List) {
    return value.map(_jsonValueFromDynamic).toList();
  }
  if (value is Map) {
    return value.map((k, v) => MapEntry('$k', _jsonValueFromDynamic(v)));
  }
  return '$value';
}

({String name, Map<String, Object?> arguments}) _parseNativeToolRequest(
  String json,
) {
  final decoded = jsonDecode(json);
  if (decoded is! Map) {
    throw const FormatException('tool request: expected JSON object');
  }
  final root = Map<String, Object?>.from(
    decoded.map((k, v) => MapEntry('$k', v)),
  );
  final fn = root['function'];
  if (fn is! Map) {
    throw const FormatException('tool request: missing function');
  }
  final name = fn['name'] as String?;
  if (name == null || name.isEmpty) {
    throw const FormatException('tool request: missing function.name');
  }
  return (name: name, arguments: _jsonMapFromDynamic(fn['arguments']));
}

Future<T> _withNativeToolListener<T>({
  required Map<String, Object?> basePayload,
  required Future<String> Function(String name, Map<String, Object?> args)
  onTool,
  required Future<T> Function(Map<String, Object?> payload) run,
}) async {
  late final NativeCallable<NativeFlmToolRequest> toolHook;
  toolHook = NativeCallable.listener((Pointer<Utf8> reqPtr, Pointer<Void> _) {
    final bridge = FlmNativeDispatcher();
    final json = reqPtr.toDartString();
    malloc.free(reqPtr);
    unawaited(() async {
      try {
        final parsed = _parseNativeToolRequest(json);
        final out = await onTool(parsed.name, parsed.arguments);
        bridge.completeToolBridge(out);
      } catch (e) {
        bridge.abortToolBridge('$e');
      }
    }());
  });
  try {
    final payload = <String, Object?>{
      ...basePayload,
      'toolListener': toolHook.nativeFunction.address,
    };
    return await run(payload);
  } finally {
    toolHook.close();
  }
}

Map<String, Object?> _decodeFlmPayloadJson(String jsonPayload) {
  final decoded = jsonDecode(jsonPayload);
  if (decoded is! Map) {
    throw FormatException('Expected JSON object for FLM payload');
  }
  return Map<String, Object?>.from(decoded.map((k, v) => MapEntry('$k', v)));
}

/// Top-level isolate runners only take JSON + scalars so no instance / UI
/// closures are copied with the worker closure (avoids unsendable captures).
Future<Map<String, Object?>> _isolateRunFlmInvoke(
  String operation,
  String jsonPayload,
) {
  return Isolate.run(() {
    final p = _decodeFlmPayloadJson(jsonPayload);
    return defaultFlmDispatching().invoke(operation, p);
  }, debugName: 'flm_native_dispatch');
}

Future<Map<String, Object?>> _isolateRunLmGenerateStream(
  String jsonPayload,
  int chunkAddr,
) {
  return Isolate.run(() {
    final payload = _decodeFlmPayloadJson(jsonPayload);
    final d = FlmNativeDispatcher();
    return d.invokeLmGenerateStream(payload, chunkAddr);
  }, debugName: 'flm_lm_stream');
}

FlmNativeDispatcher? flmNativeDispatcherForStream(FlmDispatching dispatch) {
  if (dispatch is FlmNativeDispatcher) {
    return dispatch;
  }
  if (dispatch is FallbackFlmDispatcher) {
    final p = dispatch.primary;
    if (p is FlmNativeDispatcher) {
      return p;
    }
  }
  return null;
}

Future<Map<String, Object?>> _invokeFlmDispatch(
  FlmDispatching dispatch,
  String operation,
  Map<String, Object?> payload, {
  bool sameIsolate = false,
}) async {
  if (sameIsolate || !dispatch.isBlockingInvoke) {
    return Future<Map<String, Object?>>.value(
      dispatch.invoke(operation, payload),
    );
  }
  return _isolateRunFlmInvoke(operation, jsonEncode(payload));
}

void _assertToolsConsistent(LmCompletionRequest request) {
  if (request.tools.isEmpty) {
    return;
  }
  if (request.onToolCall == null) {
    throw StateError(
      'LmCompletionRequest.tools is non-empty but onToolCall is null.',
    );
  }
}

Map<String, Object?> _lmGeneratePayload(LmCompletionRequest request) {
  final hasMessages =
      request.messages != null && request.messages!.isNotEmpty;
  return <String, Object?>{
    'modelPath': request.modelPath,
    'runtimeAdapter': runtimeAdapterWireName(request.manifest.runtimeAdapter),
    // Prefer structured messages; fall back to flat prompt string.
    // Swift checks 'messages' first.
    if (hasMessages) 'messages': request.messages,
    if (!hasMessages) 'prompt': request.prompt,
    'maxTokens': request.maxTokens,
    if (request.temperature != null) 'temperature': request.temperature,
    if (request.topP != null) 'topP': request.topP,
    if (request.enableThinking != null)
      'enableThinking': request.enableThinking,
    if (request.audioPath != null) 'audioPath': request.audioPath,
    if (request.imagePath != null) 'imagePath': request.imagePath,
    if (request.tools.isNotEmpty)
      'tools': request.tools.map((t) => t.toOpenAIJson()).toList(),
  };
}

class LmCompletionRequest {
  LmCompletionRequest({
    required this.modelPath,
    required this.manifest,
    this.prompt = '',
    this.messages,
    this.audioPath,
    this.imagePath,
    this.maxTokens = 256,
    this.temperature,
    this.topP,
    this.enableThinking,
    this.tools = const <LocalTool>[],
    this.onToolCall,
  }) : assert(
         prompt.isNotEmpty || (messages != null && messages.isNotEmpty),
         'LmCompletionRequest: provide either prompt or messages',
       );

  final String modelPath;
  final LocalModelManifest manifest;

  /// Flat text prompt (legacy / fallback). Used when [messages] is null.
  final String prompt;

  /// Structured messages list. Each entry is a map with keys 'role' and
  /// 'content'. Roles: 'system', 'user', 'assistant', 'tool'.
  /// When provided, Swift builds a proper Chat.Message history and passes
  /// only the last user message to ChatSession.respond(to:).
  final List<Map<String, String>>? messages;

  final String? audioPath;
  final String? imagePath;
  final int maxTokens;
  final double? temperature;
  final double? topP;
  final bool? enableThinking;
  final List<LocalTool> tools;
  final Future<String> Function(String name, Map<String, Object?> arguments)?
  onToolCall;
}

abstract class LmEngine {
  Future<String> complete(LmCompletionRequest request);

  /// Runs the model, forwarding **delta** text chunks to [onChunk] when the
  /// runtime supports streaming; otherwise emits a single chunk with the full
  /// response at the end.
  Future<String> completeStreaming(
    LmCompletionRequest request,
    void Function(String chunk) onChunk,
  ) async {
    final text = await complete(request);
    onChunk(text);
    return text;
  }
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

bool _manifestIdLooksLikeGemma4(String id) {
  final n = id.toLowerCase().replaceAll('_', '-');
  return n.startsWith('gemma4') || n.startsWith('gemma-4');
}

/// Gemma 4 MLX audio-tower ASR is off by default (GPU/driver crashes).
/// Re-enable only after that path is verified stable.
const bool kNativeGemma4AsrEnabled = false;

bool _manifestIsGemma4VlmWithAudioInput(LocalModelManifest manifest) {
  return manifest.runtimeAdapter == RuntimeAdapter.mlxVlm &&
      manifest.tasks.contains(ModelTask.audioInput) &&
      _manifestIdLooksLikeGemma4(manifest.id);
}

bool _manifestUsesNativeGemma4Asr(LocalModelManifest manifest) {
  return kNativeGemma4AsrEnabled && _manifestIsGemma4VlmWithAudioInput(manifest);
}

String _mergePromptWithAudioTranscript(String prompt, String transcript) {
  final t = transcript.trim();
  if (t.isEmpty) {
    return prompt;
  }
  return '$prompt\n\n[user audio]: $t';
}

final class NativeLmEngine implements LmEngine {
  NativeLmEngine({FlmDispatching? dispatch})
    : _dispatch = dispatch ?? defaultFlmDispatching();

  final FlmDispatching _dispatch;

  /// The raw response map from the last `lm.generate` or `lm.generate.stream`
  /// call. Contains Swift-side timing fields when available:
  ///   `swiftCacheHit`    – bool: true if the model container was already cached
  ///   `swiftLoadMs`      – int: ms spent loading the model (0 if cache hit)
  ///   `swiftFirstTokenMs`– int: ms from generation start to first token
  ///   `swiftGenerateMs`  – int: ms for the full generation loop
  ///   `swiftTotalMs`     – int: total ms inside handleLmGenerate*
  Map<String, Object?>? lastNativeTimings;

  @override
  Future<String> complete(LmCompletionRequest request) async {
    final audio = request.audioPath;
    if (audio != null &&
        audio.isNotEmpty &&
        !kNativeGemma4AsrEnabled &&
        _manifestIsGemma4VlmWithAudioInput(request.manifest)) {
      throw StateError(
        'Gemma 4 on-device speech-to-text is disabled in this build (unstable). '
        'Use an mlx_audio ASR model (e.g. Whisper) for voice input, or type text.',
      );
    }
    if (audio != null &&
        audio.isNotEmpty &&
        _manifestUsesNativeGemma4Asr(request.manifest)) {
      final trMap = await _invokeFlmDispatch(
        _dispatch,
        'audio.transcribe',
        <String, Object?>{
          'modelPath': request.modelPath,
          'audioPath': audio,
          'max_tokens': request.maxTokens,
        },
      );
      if (trMap['ok'] != true) {
        throw StateError(trMap['error'] as String? ?? jsonEncode(trMap));
      }
      final tr = trMap['text'] as String? ?? '';
      return complete(
        LmCompletionRequest(
          modelPath: request.modelPath,
          manifest: request.manifest,
          prompt: _mergePromptWithAudioTranscript(request.prompt, tr),
          audioPath: null,
          imagePath: request.imagePath,
          maxTokens: request.maxTokens,
          temperature: request.temperature,
          topP: request.topP,
          enableThinking: request.enableThinking,
          tools: request.tools,
          onToolCall: request.onToolCall,
        ),
      );
    }

    if (!manifestSupportsTextPrompt(request.manifest)) {
      throw StateError(
        'Chat verification currently supports installed mlx_lm and mlx_vlm chat models.',
      );
    }
    _assertToolsConsistent(request);
    final payload = _lmGeneratePayload(request);
    final useTools = request.tools.isNotEmpty && request.onToolCall != null;
    final Map<String, Object?> map;
    if (useTools) {
      map = await _withNativeToolListener(
        basePayload: payload,
        onTool: request.onToolCall!,
        run: (p) => _invokeFlmDispatch(_dispatch, 'lm.generate', p),
      );
    } else {
      map = await _invokeFlmDispatch(_dispatch, 'lm.generate', payload);
    }
    lastNativeTimings = map;
    if (map['ok'] == true) {
      final text = map['text'];
      if (text is! String || text.trim().isEmpty) {
        throw StateError('Native LM returned empty text');
      }
      return text;
    }
    throw StateError(map['error'] as String? ?? jsonEncode(map));
  }

  @override
  Future<String> completeStreaming(
    LmCompletionRequest request,
    void Function(String chunk) onChunk,
  ) async {
    final audio = request.audioPath;
    if (audio != null &&
        audio.isNotEmpty &&
        !kNativeGemma4AsrEnabled &&
        _manifestIsGemma4VlmWithAudioInput(request.manifest)) {
      throw StateError(
        'Gemma 4 on-device speech-to-text is disabled in this build (unstable). '
        'Use an mlx_audio ASR model (e.g. Whisper) for voice input, or type text.',
      );
    }
    if (audio != null &&
        audio.isNotEmpty &&
        _manifestUsesNativeGemma4Asr(request.manifest)) {
      final trMap = await _invokeFlmDispatch(
        _dispatch,
        'audio.transcribe',
        <String, Object?>{
          'modelPath': request.modelPath,
          'audioPath': audio,
          'max_tokens': request.maxTokens,
        },
      );
      if (trMap['ok'] != true) {
        throw StateError(trMap['error'] as String? ?? jsonEncode(trMap));
      }
      final tr = trMap['text'] as String? ?? '';
      return completeStreaming(
        LmCompletionRequest(
          modelPath: request.modelPath,
          manifest: request.manifest,
          prompt: _mergePromptWithAudioTranscript(request.prompt, tr),
          audioPath: null,
          imagePath: request.imagePath,
          maxTokens: request.maxTokens,
          temperature: request.temperature,
          topP: request.topP,
          enableThinking: request.enableThinking,
          tools: request.tools,
          onToolCall: request.onToolCall,
        ),
        onChunk,
      );
    }

    if (!manifestSupportsTextPrompt(request.manifest)) {
      throw StateError(
        'Chat verification currently supports installed mlx_lm and mlx_vlm chat models.',
      );
    }
    _assertToolsConsistent(request);
    final payload = _lmGeneratePayload(request);
    final useTools = request.tools.isNotEmpty && request.onToolCall != null;

    if (useTools) {
      return _withNativeToolListener(
        basePayload: payload,
        onTool: request.onToolCall!,
        run: (payloadWithListener) async {
          if (flmNativeDispatcherForStream(_dispatch) == null) {
            final text = await complete(request);
            onChunk(text);
            return text;
          }

          late final NativeCallable<NativeFlmStreamChunk> chunkHook;
          chunkHook = NativeCallable<NativeFlmStreamChunk>.listener((
            Pointer<Utf8> ptr,
            Pointer<Void> _,
          ) {
            if (ptr.address == 0) {
              return;
            }
            try {
              final delta = ptr.toDartString();
              if (delta.isNotEmpty) {
                onChunk(delta);
              }
            } finally {
              malloc.free(ptr);
            }
          });

          try {
            final addr = chunkHook.nativeFunction.address;
            final map = await _isolateRunLmGenerateStream(
              jsonEncode(payloadWithListener),
              addr,
            );
            lastNativeTimings = map;
            if (map['ok'] == true) {
              final text = map['text'];
              if (text is! String || text.trim().isEmpty) {
                throw StateError('Native LM returned empty text');
              }
              return text;
            }
            throw StateError(map['error'] as String? ?? jsonEncode(map));
          } finally {
            chunkHook.close();
          }
        },
      );
    }

    final streamNative = flmNativeDispatcherForStream(_dispatch);
    if (streamNative == null) {
      final text = await complete(request);
      onChunk(text);
      return text;
    }

    late final NativeCallable<NativeFlmStreamChunk> chunkHook;
    chunkHook = NativeCallable<NativeFlmStreamChunk>.listener((
      Pointer<Utf8> ptr,
      Pointer<Void> _,
    ) {
      if (ptr.address == 0) {
        return;
      }
      try {
        final delta = ptr.toDartString();
        if (delta.isNotEmpty) {
          onChunk(delta);
        }
      } finally {
        malloc.free(ptr);
      }
    });

    try {
      final addr = chunkHook.nativeFunction.address;
      final map = await _isolateRunLmGenerateStream(jsonEncode(payload), addr);
      lastNativeTimings = map;
      if (map['ok'] == true) {
        final text = map['text'];
        if (text is! String || text.trim().isEmpty) {
          throw StateError('Native LM returned empty text');
        }
        return text;
      }
      throw StateError(map['error'] as String? ?? jsonEncode(map));
    } finally {
      chunkHook.close();
    }
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
    : _dispatch = dispatch ?? defaultFlmDispatching();

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
        'Speech-to-text requires an installed mlx_audio ASR model (e.g. Whisper).',
      );
    }
    final map = await _invokeFlmDispatch(
      _dispatch,
      'audio.transcribe',
      <String, Object?>{
        'modelPath': modelPath,
        'audioPath': audioPath,
        'max_tokens': 256,
        if (language != null && language.trim().isNotEmpty)
          'language': language.trim(),
      },
    );
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
    final map = await _invokeFlmDispatch(
      _dispatch,
      'audio.synthesize',
      payload,
    );
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
    : _dispatch = dispatch ?? defaultFlmDispatching();

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
    final map =
        await _invokeFlmDispatch(_dispatch, 'image.generate', <String, Object?>{
          'modelPath': modelPath,
          'manifestId': manifest.id,
          'displayName': manifest.displayName,
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

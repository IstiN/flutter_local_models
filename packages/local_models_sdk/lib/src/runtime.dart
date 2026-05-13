import 'dart:convert';

import 'package:local_models_core/local_models_core.dart';

import 'model_store.dart';

const int _maxEmbeddedGemmaToolIterations = 3;

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
    this.tools = const <LocalTool>[],
    this.onToolCall,
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
  final List<LocalTool> tools;
  final Future<String> Function(String name, Map<String, Object?> arguments)?
  onToolCall;
}

abstract interface class LmEngine {
  Future<String> complete(LmCompletionRequest request);

  Future<String> completeStreaming(
    LmCompletionRequest request,
    void Function(String chunk) onChunk,
  ) async {
    final text = await complete(request);
    onChunk(text);
    return text;
  }
}

/// Abstraction for [StreamingVoice2VoicePipeline] so hosts can supply their own
/// chat runner (e.g. Flutter Studio with attachment-aware prompts).
abstract interface class StreamingChatRunner {
  Future<String> chatStream({
    required InstalledModel model,
    required List<LocalChatMessage> messages,
    required void Function(String text) onText,
    LocalChatParams params = const LocalChatParams(),
    LmToolRegistry? toolRegistry,
  });
}

final class LmToolRegistry {
  final Map<String, Future<String> Function(Map<String, Object?>)> _handlers =
      <String, Future<String> Function(Map<String, Object?>)>{};

  void register(
    String name,
    Future<String> Function(Map<String, Object?> arguments) handler,
  ) {
    _handlers[name] = handler;
  }

  void registerSync(
    String name,
    String Function(Map<String, Object?> arguments) handler,
  ) {
    _handlers[name] = (args) async => handler(args);
  }

  bool provides(String name) => _handlers.containsKey(name);

  Future<String> invoke(String name, Map<String, Object?> arguments) async {
    final handler = _handlers[name];
    if (handler == null) {
      throw StateError('No tool handler registered for "$name".');
    }
    return handler(arguments);
  }
}

class LocalChatRunner implements StreamingChatRunner {
  LocalChatRunner({required LmEngine engine}) : _engine = engine;

  final LmEngine _engine;

  @override
  Future<String> chatStream({
    required InstalledModel model,
    required List<LocalChatMessage> messages,
    required void Function(String text) onText,
    LocalChatParams params = const LocalChatParams(),
    LmToolRegistry? toolRegistry,
  }) async {
    final requestedModelId = params.modelId;
    if (requestedModelId != null && requestedModelId != model.manifest.id) {
      throw StateError(
        'Selected runtime model ${model.manifest.id} does not match requested model $requestedModelId.',
      );
    }
    if (params.tools.isNotEmpty && toolRegistry == null) {
      throw StateError(
        'LocalChatParams.tools is non-empty; pass an LmToolRegistry with handlers.',
      );
    }
    final toolHandler = _toolCallHandler(params.tools, toolRegistry?.invoke);
    final prompt = promptFromMessages(messages);
    final buffer = StringBuffer();
    final raw = await _engine.completeStreaming(
      LmCompletionRequest(
        modelPath: model.directory.path,
        manifest: model.manifest,
        prompt: prompt,
        maxTokens: params.maxTokens,
        temperature: params.temperature,
        topP: params.topP,
        enableThinking: params.enableThinking,
        tools: params.tools,
        onToolCall: toolHandler,
      ),
      (delta) {
        buffer.write(delta);
        final stripped = stripEmbeddedGemmaToolCallBlocks(buffer.toString());
        final soFar = stripped.trim();
        if (soFar.isNotEmpty) {
          onText(soFar);
        }
      },
    );
    final text = params.tools.isEmpty || toolHandler == null
        ? stripEmbeddedGemmaToolCallBlocks(raw).trim()
        : await _completeEmbeddedGemmaToolLoop(
            engine: _engine,
            model: model,
            prompt: prompt,
            params: params,
            onToolCall: toolHandler,
            rawModelOutput: raw,
          );
    if (text.isNotEmpty) {
      onText(text);
    }
    return text;
  }
}

final RegExp _gemmaToolBlockRe = RegExp(
  r'(?:<\|tool_call\|>|<\|tool_call>|<tool_call\|>|<tool_call>)\s*'
  r'call:\s*([a-zA-Z0-9_]+)\s*'
  r'(?:\{([\s\S]*?)\}|\(([\s\S]*?)\))\s*'
  r'(?:<\|tool_call\|>|<\|tool_call>|<tool_call\|>|<tool_call>|</tool_call>)',
  multiLine: true,
);

const List<String> _gemmaToolTagOpenVariants = <String>[
  '<|tool_call|>',
  '<|tool_call>',
  '<tool_call|>',
  '<tool_call>',
];

String stripEmbeddedGemmaToolCallBlocks(String text) {
  final stripped = text.replaceAll(_gemmaToolBlockRe, '');
  final partialStart = _lastGemmaToolTagStartIndex(stripped);
  if (partialStart == -1) {
    return stripped.trimRight();
  }
  return stripped.substring(0, partialStart).trimRight();
}

int _lastGemmaToolTagStartIndex(String text) {
  var best = -1;
  for (final tag in _gemmaToolTagOpenVariants) {
    final i = text.lastIndexOf(tag);
    if (i > best) {
      best = i;
    }
  }
  return best;
}

final class _EmbeddedGemmaToolInvocation {
  const _EmbeddedGemmaToolInvocation(this.name, this.argsBody);

  final String name;
  final String argsBody;
}

List<_EmbeddedGemmaToolInvocation> _extractEmbeddedGemmaToolCalls(String text) {
  final matches = _gemmaToolBlockRe.allMatches(text).toList(growable: false);
  if (matches.isEmpty) {
    return const <_EmbeddedGemmaToolInvocation>[];
  }
  return matches
      .map(
        (match) => _EmbeddedGemmaToolInvocation(
          match.group(1)!,
          match.group(2) ?? match.group(3) ?? '',
        ),
      )
      .toList(growable: false);
}

Map<String, Object?> _parseEmbeddedGemmaToolArgs(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) {
    return const <String, Object?>{};
  }
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) {
      return Map<String, Object?>.from(
        decoded.map((key, value) => MapEntry('$key', value)),
      );
    }
  } catch (_) {}

  final jsonish = _gemmaArgsToJsonObjectString(trimmed);
  try {
    final decoded = jsonDecode(jsonish);
    if (decoded is Map) {
      return Map<String, Object?>.from(
        decoded.map((key, value) => MapEntry('$key', value)),
      );
    }
  } catch (_) {}
  return const <String, Object?>{};
}

String _gemmaArgsToJsonObjectString(String body) {
  final replaced = body.replaceAllMapped(
    RegExp(r'([a-zA-Z0-9_]+)\s*:\s*<\|"\|>([\s\S]*?)<\|"\|>'),
    (match) => '"${match.group(1)!}":${jsonEncode(match.group(2)!)}',
  );
  final trimmed = replaced.trim();
  return trimmed.startsWith('{') ? trimmed : '{$trimmed}';
}

Future<String> _completeEmbeddedGemmaToolLoop({
  required LmEngine engine,
  required InstalledModel model,
  required String prompt,
  required LocalChatParams params,
  required Future<String> Function(String name, Map<String, Object?> args)
  onToolCall,
  required String rawModelOutput,
}) async {
  var currentPrompt = prompt;
  var currentRaw = rawModelOutput;
  var lastToolResults = const <_GemmaToolResult>[];

  for (var i = 0; i < _maxEmbeddedGemmaToolIterations; i++) {
    final calls = _extractEmbeddedGemmaToolCalls(currentRaw);
    if (calls.isEmpty) {
      return stripEmbeddedGemmaToolCallBlocks(currentRaw).trim();
    }

    lastToolResults = await _invokeEmbeddedGemmaTools(calls, onToolCall);
    currentPrompt = _appendEmbeddedGemmaToolResultsToPrompt(
      prompt: currentPrompt,
      rawAssistantOutput: currentRaw,
      toolResults: lastToolResults,
    );
    currentRaw = await engine.complete(
      LmCompletionRequest(
        modelPath: model.directory.path,
        manifest: model.manifest,
        prompt: currentPrompt,
        maxTokens: params.maxTokens,
        temperature: params.temperature,
        topP: params.topP,
        enableThinking: params.enableThinking,
        tools: const <LocalTool>[],
        onToolCall: null,
      ),
    );
  }

  return _formatEmbeddedGemmaToolResults(lastToolResults).trim();
}

Future<List<_GemmaToolResult>> _invokeEmbeddedGemmaTools(
  List<_EmbeddedGemmaToolInvocation> calls,
  Future<String> Function(String name, Map<String, Object?> args) onToolCall,
) async {
  final results = <_GemmaToolResult>[];
  for (final call in calls) {
    final args = _parseEmbeddedGemmaToolArgs(call.argsBody);
    final output = (await onToolCall(call.name, args)).trim();
    results.add(_GemmaToolResult(call.name, args, output));
  }
  return results;
}

String _appendEmbeddedGemmaToolResultsToPrompt({
  required String prompt,
  required String rawAssistantOutput,
  required List<_GemmaToolResult> toolResults,
}) {
  final buffer = StringBuffer();
  final base = prompt.trim();
  if (base.isNotEmpty) {
    buffer.writeln(base);
    buffer.writeln();
  }
  final assistantText = stripEmbeddedGemmaToolCallBlocks(
    rawAssistantOutput,
  ).trim();
  if (assistantText.isNotEmpty) {
    buffer.writeln('assistant: $assistantText');
  }
  buffer.writeln(
    'tool: The assistant called tool(s). Use these result(s) to answer the user naturally. Do not expose raw JSON unless the user asks for it.',
  );
  buffer.write(_formatEmbeddedGemmaToolResults(toolResults));
  buffer.writeln();
  buffer.write('assistant:');
  return buffer.toString().trim();
}

String _formatEmbeddedGemmaToolResults(List<_GemmaToolResult> results) {
  return results
      .map(
        (result) =>
            '[${result.name}] arguments=${jsonEncode(result.arguments)} result=${result.output}',
      )
      .join('\n');
}

final class _GemmaToolResult {
  const _GemmaToolResult(this.name, this.arguments, this.output);

  final String name;
  final Map<String, Object?> arguments;
  final String output;
}

Future<String> Function(String name, Map<String, Object?> args)?
_toolCallHandler(
  List<LocalTool> tools,
  Future<String> Function(String name, Map<String, Object?> args)? onToolCall,
) {
  if (tools.isEmpty || onToolCall == null) {
    return null;
  }
  return (name, args) {
    if (_isToolListRequest(name)) {
      return Future<String>.value(_encodeAvailableTools(tools));
    }
    return onToolCall(name, args);
  };
}

bool _isToolListRequest(String name) {
  return name == 'get_tools' ||
      name == 'list_tools' ||
      name == 'get_available_tools';
}

String _encodeAvailableTools(List<LocalTool> tools) {
  return jsonEncode(<String, Object?>{
    'tools': tools.map((tool) => tool.toOpenAIJson()).toList(growable: false),
  });
}

String promptFromMessages(List<LocalChatMessage> messages) {
  final buffer = StringBuffer();
  for (final message in messages) {
    final content = message.content.trim();
    if (content.isEmpty) {
      continue;
    }
    buffer.writeln('${localChatRoleToString(message.role)}: $content');
  }
  buffer.write('assistant:');
  return buffer.toString().trim();
}

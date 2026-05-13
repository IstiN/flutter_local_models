import 'dart:convert';

const List<String> _gemmaToolTagOpenVariants = <String>[
  '<|tool_call|>',
  '<|tool_call>',
  '<tool_call|>',
  '<tool_call>',
];

/// Gemma (and some MLX chat templates) may emit tool usage as plain tokens
/// instead of invoking native [toolDispatch]. Delimiters vary by template:
/// - `<|tool_call|>call:name{...}<|tool_call|>`
/// - `<|tool_call>call:name{...}<tool_call|>`
/// - `<tool_call>call:name(args)</tool_call>`
final RegExp _gemmaToolBlockRe = RegExp(
  r'(?:<\|tool_call\|>|<\|tool_call>|<tool_call\|>|<tool_call>)\s*'
  r'call:\s*([a-zA-Z0-9_]+)\s*'
  r'(?:\{([\s\S]*?)\}|\(([\s\S]*?)\))\s*'
  r'(?:<\|tool_call\|>|<\|tool_call>|<tool_call\|>|<tool_call>|</tool_call>)',
  multiLine: true,
);

/// Removes complete embedded tool blocks from [text]. For streaming, also hides
/// an incomplete trailing tool block so the UI does not flash raw tokens.
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
  for (final t in _gemmaToolTagOpenVariants) {
    final i = text.lastIndexOf(t);
    if (i > best) {
      best = i;
    }
  }
  return best;
}

class EmbeddedGemmaToolInvocation {
  const EmbeddedGemmaToolInvocation(this.name, this.argsBody);

  final String name;
  final String argsBody;
}

List<EmbeddedGemmaToolInvocation> extractEmbeddedGemmaToolCalls(String text) {
  final matches = _gemmaToolBlockRe.allMatches(text).toList(growable: false);
  if (matches.isEmpty) {
    return const <EmbeddedGemmaToolInvocation>[];
  }
  return matches
      .map(
        (m) => EmbeddedGemmaToolInvocation(
          m.group(1)!,
          m.group(2) ?? m.group(3) ?? '',
        ),
      )
      .toList(growable: false);
}

/// Best-effort map for `call:foo{a:1}` JSON, Gemma-quoted strings
/// `key:<|"|>value<|"|>`, or empty `{}`.
Map<String, Object?> parseEmbeddedGemmaToolArgs(String body) {
  final b = body.trim();
  if (b.isEmpty) {
    return const <String, Object?>{};
  }
  try {
    final j = jsonDecode(b);
    if (j is Map) {
      return Map<String, Object?>.from(j.map((k, v) => MapEntry('$k', v)));
    }
  } catch (_) {}

  final jsonish = _gemmaArgsToJsonObjectString(b);
  try {
    final j = jsonDecode(jsonish);
    if (j is Map) {
      return Map<String, Object?>.from(j.map((k, v) => MapEntry('$k', v)));
    }
  } catch (_) {}

  return const <String, Object?>{};
}

String _gemmaArgsToJsonObjectString(String b) {
  final replaced = b.replaceAllMapped(
    RegExp(r'([a-zA-Z0-9_]+)\s*:\s*<\|"\|>([\s\S]*?)<\|"\|>'),
    (m) {
      final key = m.group(1)!;
      final val = jsonEncode(m.group(2)!);
      return '"$key":$val';
    },
  );
  final t = replaced.trim();
  if (t.startsWith('{')) {
    return t;
  }
  return '{$t}';
}

/// If [rawModelOutput] contains embedded Gemma-style tool calls, invokes [onTool]
/// for each and returns a user-visible string (non-tool text + tool results).
/// Otherwise returns [stripEmbeddedGemmaToolCallBlocks] applied to [cleanedOutput].
Future<String> applyEmbeddedGemmaToolCallsIfAny({
  required String rawModelOutput,
  required String cleanedOutput,
  required Future<String> Function(String name, Map<String, Object?> args)
  onTool,
}) async {
  final calls = extractEmbeddedGemmaToolCalls(rawModelOutput);
  if (calls.isEmpty) {
    return stripEmbeddedGemmaToolCallBlocks(cleanedOutput).trim();
  }
  final preamble = stripEmbeddedGemmaToolCallBlocks(cleanedOutput).trim();
  final lines = <String>[];
  if (preamble.isNotEmpty) {
    lines.add(preamble);
  }
  for (final c in calls) {
    final args = parseEmbeddedGemmaToolArgs(c.argsBody);
    final result = (await onTool(c.name, args)).trim();
    lines.add('[${c.name}] $result');
  }
  final out = lines.join('\n\n').trim();
  return out.isEmpty ? '(Tool completed)' : out;
}

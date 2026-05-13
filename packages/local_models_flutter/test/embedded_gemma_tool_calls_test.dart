import 'package:flutter_test/flutter_test.dart';
import 'package:local_models_flutter/runtime/embedded_gemma_tool_calls.dart';

void main() {
  test('extract and strip symmetric <|tool_call|> blocks', () {
    const raw = r'hello <|tool_call|>call:get_current_time{}<|tool_call|> tail';
    final calls = extractEmbeddedGemmaToolCalls(raw);
    expect(calls.length, 1);
    expect(calls.single.name, 'get_current_time');
    expect(calls.single.argsBody, '');
    expect(
      stripEmbeddedGemmaToolCallBlocks(
        raw,
      ).replaceAll(RegExp(r' +'), ' ').trim(),
      'hello tail',
    );
  });

  test('parse Gemma quoted string args', () {
    const raw =
        r'<|tool_call|>call:echo_message{message:<|"|>привет<|"|>}<|tool_call|>';
    final calls = extractEmbeddedGemmaToolCalls(raw);
    expect(calls.single.name, 'echo_message');
    final args = parseEmbeddedGemmaToolArgs(calls.single.argsBody);
    expect(args['message'], 'привет');
  });

  test('parse Gemma quoted string args with asymmetric close', () {
    const raw =
        r'<|tool_call|>call:echo_message{message:<|"|>привет<|"|>}<tool_call|>';
    final calls = extractEmbeddedGemmaToolCalls(raw);
    expect(calls.single.name, 'echo_message');
    expect(
      parseEmbeddedGemmaToolArgs(calls.single.argsBody)['message'],
      'привет',
    );
  });

  test('extracts when open tag is <|tool_call> (without trailing pipe)', () {
    const raw = r'<|tool_call>call:get_current_time{}<tool_call|>';
    final calls = extractEmbeddedGemmaToolCalls(raw);
    expect(calls.length, 1);
    expect(calls.single.name, 'get_current_time');
    expect(calls.single.argsBody, '');
  });

  test('strip hides incomplete trailing tool blocks while streaming', () {
    const raw = 'prefix <|tool_call>call:get_current_time{';
    expect(stripEmbeddedGemmaToolCallBlocks(raw), 'prefix');
  });

  test('applyEmbeddedGemmaToolCallsIfAny invokes handler', () async {
    const raw = r'<|tool_call|>call:get_current_time{}<tool_call|>';
    var invoked = false;
    final out = await applyEmbeddedGemmaToolCallsIfAny(
      rawModelOutput: raw,
      cleanedOutput: raw,
      onTool: (name, args) async {
        expect(name, 'get_current_time');
        expect(args, isEmpty);
        invoked = true;
        return '{"ok":true}';
      },
    );
    expect(invoked, isTrue);
    expect(out, contains('get_current_time'));
    expect(out, contains('{"ok":true}'));
  });
}

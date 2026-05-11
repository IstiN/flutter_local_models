import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_models_flutter/openai_audio_speech_client.dart';

void main() {
  test('streamSpeech posts JSON with stream true and yields response bytes',
      () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() async {
      await server.close(force: true);
    });

    final seenBodies = <String>[];
    server.listen((request) async {
      if (request.method != 'POST') {
        request.response.statusCode = 405;
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      seenBodies.add(body);
      request.response.statusCode = 200;
      request.response.add(Uint8List.fromList([1, 2, 3]));
      request.response.add(Uint8List.fromList([4, 5]));
      await request.response.close();
    });

    final uri = Uri.parse('http://127.0.0.1:${server.port}/v1/audio/speech');
    final client = OpenAiAudioSpeechClient();
    addTearDown(client.close);

    final chunks = await client
        .streamSpeech(
          endpoint: uri,
          model: 'test-tts',
          input: 'hello',
          voice: 'alex',
          responseFormat: 'opus',
        )
        .toList();

    expect(chunks.length, 2);
    expect(chunks[0], [1, 2, 3]);
    expect(chunks[1], [4, 5]);

    expect(seenBodies, hasLength(1));
    final decoded = jsonDecode(seenBodies.single) as Map<String, dynamic>;
    expect(decoded['model'], 'test-tts');
    expect(decoded['input'], 'hello');
    expect(decoded['voice'], 'alex');
    expect(decoded['response_format'], 'opus');
    expect(decoded['stream'], true);
  });

  test('streamSpeech throws on non-2xx', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() async {
      await server.close(force: true);
    });

    server.listen((request) async {
      request.response.statusCode = 500;
      request.response.write('fail');
      await request.response.close();
    });

    final uri = Uri.parse('http://127.0.0.1:${server.port}/v1/audio/speech');
    final client = OpenAiAudioSpeechClient();
    addTearDown(client.close);

    await expectLater(
      client.streamSpeech(endpoint: uri, model: 'm', input: 'x').toList(),
      throwsA(isA<StateError>()),
    );
  });
}

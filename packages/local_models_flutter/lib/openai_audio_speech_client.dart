import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class OpenAiAudioSpeechClient {
  OpenAiAudioSpeechClient({
    this.apiKey,
    HttpClient? httpClient,
  }) : _ownsClient = httpClient == null,
       _client = httpClient ?? HttpClient();

  final String? apiKey;
  final HttpClient _client;
  final bool _ownsClient;

  /// Streams raw response bytes from an OpenAI-style speech endpoint.
  ///
  /// Request body includes `"stream": true` as required by compatible servers.
  Stream<Uint8List> streamSpeech({
    required Uri endpoint,
    required String model,
    required String input,
    String voice = '',
    String responseFormat = 'opus',
    Map<String, Object?> extra = const <String, Object?>{},
  }) async* {
    final request = await _client.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    final trimmedKey = apiKey?.trim() ?? '';
    if (trimmedKey.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $trimmedKey');
    }
    final body = <String, Object?>{
      'model': model,
      'input': input,
      'response_format': responseFormat,
      'stream': true,
      if (voice.trim().isNotEmpty) 'voice': voice.trim(),
      ...extra,
    };
    request.write(jsonEncode(body));
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final err = await response.transform(utf8.decoder).join();
      throw StateError('Speech HTTP ${response.statusCode}: $err');
    }
    await for (final chunk in response) {
      if (chunk.isNotEmpty) {
        yield Uint8List.fromList(chunk);
      }
    }
  }

  void close() {
    if (_ownsClient) {
      _client.close(force: true);
    }
  }
}

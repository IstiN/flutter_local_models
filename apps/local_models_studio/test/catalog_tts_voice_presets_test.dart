import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_models_core/local_models_core.dart';

void main() {
  test('catalog Qwen3 TTS Base exposes same CustomVoice speaker enum', () {
    final raw = File('assets/catalog.json').readAsStringSync();
    final list = jsonDecode(raw) as List<dynamic>;
    final entry = list.cast<Map<String, dynamic>>().firstWhere(
      (e) => e['id'] == 'qwen3-tts-12hz-0.6b-base-4bit',
    );
    final manifest = LocalModelManifest.fromJsonMap(entry);
    final props = manifest.runtimeConfig.parameterSchema['properties']
        as Map<String, Object?>?;
    final voice = props?['voice'] as Map<String, Object?>?;
    final enums = (voice?['enum'] as List<dynamic>?)?.cast<String>() ?? [];
    expect(enums, contains('Vivian'));
    expect(enums, contains('Sohee'));
    expect(
      manifest.runtimeConfig.extra['supports_speaker_presets'],
      true,
    );
  });

  test('catalog CustomVoice exposes nine named speakers in schema', () {
    final raw = File('assets/catalog.json').readAsStringSync();
    final list = jsonDecode(raw) as List<dynamic>;
    final entry = list.cast<Map<String, dynamic>>().firstWhere(
      (e) => e['id'] == 'qwen3-tts-12hz-0.6b-customvoice-4bit',
    );
    final manifest = LocalModelManifest.fromJsonMap(entry);
    final voiceEnum = manifest.runtimeConfig.parameterSchema['properties']
        as Map<String, Object?>?;
    final voice = voiceEnum?['voice'] as Map<String, Object?>?;
    final enums = (voice?['enum'] as List<dynamic>?)?.cast<String>() ?? [];
    expect(enums, contains('Ryan'));
    expect(enums.length, greaterThanOrEqualTo(9));
    expect(
      manifest.runtimeConfig.extra['qwen_tts_mode'],
      'custom_voice',
    );
  });

  test('catalog VibeVoice Realtime exposes voice enum for UI presets', () {
    final raw = File('assets/catalog.json').readAsStringSync();
    final registry = ModelRegistry.fromCatalogJson(raw);
    final manifest = registry.manifests.firstWhere(
      (m) => m.id == 'vibevoice-realtime-0.5b-4bit',
    );
    final props = manifest.runtimeConfig.parameterSchema['properties']
        as Map<String, Object?>?;
    final voice = props?['voice'] as Map<String, Object?>?;
    final enums = (voice?['enum'] as List<dynamic>?)?.cast<String>() ?? [];
    expect(enums, contains('en-Emma_woman'));
    expect(enums, contains('en-Carter_man'));
    expect(enums, contains('en-Davis_man'));
    expect(enums.length, greaterThanOrEqualTo(6));
    expect(manifest.runtimeConfig.extra['vibevoice_tts_mode'], 'realtime');
  });
}

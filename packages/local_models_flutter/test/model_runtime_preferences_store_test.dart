import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_models_flutter/local_models_flutter.dart';
import 'package:path/path.dart' as p;

void main() {
  test('mergeModelPrefs persists and prefsForModel reads back', () async {
    final dir = await Directory.systemTemp.createTemp('flm-prefs-');
    addTearDown(() async {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    });
    final store = ModelRuntimePreferencesStore(
      paths: StudioPaths(baseDirectory: dir),
    );
    await store.mergeModelPrefs('model-a', {
      'generation': {'maxTokens': 512},
      'tts': {'voice': 'Ryan'},
    });
    expect(store.prefsForModel('model-a')!['generation'], {'maxTokens': 512});
    expect(store.prefsForModel('model-a')!['tts'], {'voice': 'Ryan'});

    await store.mergeModelPrefs('model-a', {
      'generation': {'maxTokens': 256, 'temperature': 0.5},
      'streamingSpeech': true,
    });
    final after = store.prefsForModel('model-a')!;
    expect(after['generation'], {'maxTokens': 256, 'temperature': 0.5});
    expect(after['tts'], {'voice': 'Ryan'});
    expect(after['streamingSpeech'], true);

    final file = File(p.join(dir.path, 'model_runtime_prefs.json'));
    expect(file.existsSync(), isTrue);
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final models = decoded['models'] as Map;
    expect(models.containsKey('model-a'), isTrue);
  });

  test('mergeModelPrefs null value removes key', () async {
    final dir = await Directory.systemTemp.createTemp('flm-prefs-');
    addTearDown(() async {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    });
    final store = ModelRuntimePreferencesStore(
      paths: StudioPaths(baseDirectory: dir),
    );
    await store.mergeModelPrefs('x', {'foo': 'bar'});
    await store.mergeModelPrefs('x', {'foo': null});
    expect(store.prefsForModel('x')!.containsKey('foo'), isFalse);
  });

  test('prefsForModel returns null for missing id', () {
    final dir = Directory.systemTemp.createTempSync('flm-prefs-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = ModelRuntimePreferencesStore(
      paths: StudioPaths(baseDirectory: dir),
    );
    expect(store.prefsForModel('none'), isNull);
  });
}

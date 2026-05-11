import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'studio_services.dart';

/// Persists per-model UI/runtime choices (generation params, TTS fields, etc.).
class ModelRuntimePreferencesStore {
  ModelRuntimePreferencesStore({required this.paths});

  final StudioPaths paths;

  File get _file =>
      File(p.join(paths.baseDirectory.path, 'model_runtime_prefs.json'));

  Map<String, Object?> _readRootSync() {
    if (!_file.existsSync()) {
      return <String, Object?>{};
    }
    try {
      final raw = jsonDecode(_file.readAsStringSync());
      if (raw is Map) {
        return Map<String, Object?>.from(
          raw.map((k, v) => MapEntry('$k', v)),
        );
      }
    } catch (_) {}
    return <String, Object?>{};
  }

  /// Snapshot for one catalog model id (e.g. `qwen3-tts-...`), or null.
  Map<String, Object?>? prefsForModel(String modelId) {
    final root = _readRootSync();
    final models = root['models'];
    if (models is! Map) {
      return null;
    }
    final entry = models[modelId];
    if (entry is! Map) {
      return null;
    }
    return Map<String, Object?>.from(
      entry.map((key, value) => MapEntry('$key', value)),
    );
  }

  Future<void> mergeModelPrefs(
    String modelId,
    Map<String, Object?> patch,
  ) async {
    final root = Map<String, Object?>.from(_readRootSync());
    final rawModels = root['models'] as Map?;
    final models = Map<String, Object?>.from(
      rawModels?.map((k, v) => MapEntry('$k', v)) ??
          const <String, Object?>{},
    );
    final rawPrev = models[modelId] as Map?;
    final previous = Map<String, Object?>.from(
      rawPrev?.map((k, v) => MapEntry('$k', v)) ??
          const <String, Object?>{},
    );
    patch.forEach((key, value) {
      if (value == null) {
        previous.remove(key);
      } else {
        previous[key] = value;
      }
    });
    models[modelId] = previous;
    root['models'] = models;
    await _file.parent.create(recursive: true);
    await _file.writeAsString(const JsonEncoder.withIndent('  ').convert(root));
  }
}

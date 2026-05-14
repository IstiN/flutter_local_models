import 'dart:convert';
import 'dart:io';

import 'package:local_models_core/local_models_core.dart';
import 'package:path/path.dart' as p;

const String installMetadataFileName = '.flutter_local_model.json';

class LocalModelsSdkPaths {
  const LocalModelsSdkPaths({required this.baseDirectory});

  final Directory baseDirectory;

  Directory get downloadsDirectory =>
      Directory(p.join(baseDirectory.path, 'downloads'));
  Directory get modelsDirectory =>
      Directory(p.join(baseDirectory.path, 'models'));
  Directory get voiceReferencesDirectory =>
      Directory(p.join(baseDirectory.path, 'voice_references'));
  File get downloadQueueFile =>
      File(p.join(baseDirectory.path, 'download_queue.json'));
  File get settingsFile => File(p.join(baseDirectory.path, 'settings.json'));

  /// Default paths are deterministic for headless SDK and Flutter apps.
  ///
  /// If the sandboxed Studio container exists, SDK uses it so CLI and Studio
  /// see the same installed models. Otherwise it falls back to Application
  /// Support, then to `.flutter_local_models` when HOME is unavailable.
  static LocalModelsSdkPaths forCurrentUser({String? homeDirectory}) {
    final home = homeDirectory ?? Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return LocalModelsSdkPaths(
        baseDirectory: Directory(
          p.join(Directory.current.path, '.flutter_local_models'),
        ),
      );
    }

    final containerDirectory = Directory(
      p.join(
        home,
        'Library',
        'Containers',
        'com.example.localModelsStudio',
        'Data',
        'Library',
        'Application Support',
        'flutter_local_models',
      ),
    );
    if (containerDirectory.existsSync()) {
      return LocalModelsSdkPaths(baseDirectory: containerDirectory);
    }

    return LocalModelsSdkPaths(
      baseDirectory: Directory(
        p.join(home, 'Library', 'Application Support', 'flutter_local_models'),
      ),
    );
  }

  Future<void> ensureCreated() async {
    await baseDirectory.create(recursive: true);
    await downloadsDirectory.create(recursive: true);
    await modelsDirectory.create(recursive: true);
  }
}

class InstalledModel {
  const InstalledModel({
    required this.manifest,
    required this.directory,
    required this.sourceLabel,
    required this.installedAt,
    required this.sizeBytes,
    this.metadataUpdatedAt,
  });

  final LocalModelManifest manifest;
  final Directory directory;
  final String sourceLabel;
  final DateTime installedAt;
  final int sizeBytes;
  final DateTime? metadataUpdatedAt;

  bool get chatSupported =>
      manifest.tasks.contains(ModelTask.chat) &&
      manifest.runtimeAdapter == RuntimeAdapter.mlxLm;

  bool get textPromptSupported =>
      manifest.tasks.contains(ModelTask.chat) &&
      (manifest.runtimeAdapter == RuntimeAdapter.mlxLm ||
          manifest.runtimeAdapter == RuntimeAdapter.mlxVlm);

  bool get audioPromptSupported =>
      manifest.tasks.contains(ModelTask.audioInput) &&
      manifest.runtimeAdapter == RuntimeAdapter.mlxVlm;

  bool get speechToTextSupported =>
      manifest.tasks.contains(ModelTask.speechToText) &&
      manifest.runtimeAdapter == RuntimeAdapter.mlxAudio;

  bool get dedicatedSpeechToTextModel =>
      manifest.tasks.contains(ModelTask.speechToText) &&
      manifest.runtimeAdapter == RuntimeAdapter.mlxAudio;

  bool get textToSpeechSupported =>
      manifest.tasks.contains(ModelTask.textToSpeech) &&
      manifest.runtimeAdapter == RuntimeAdapter.mlxAudio;

  bool get imageGenerationSupported =>
      manifest.tasks.contains(ModelTask.imageGeneration) &&
      manifest.runtimeAdapter == RuntimeAdapter.mflux;

  bool get toolCallingUiSupported =>
      textPromptSupported &&
      (manifest.capabilities.toolCalling ||
          (manifest.runtimeAdapter == RuntimeAdapter.mlxVlm &&
              manifest.tasks.contains(ModelTask.chat) &&
              manifestIdLooksLikeGemma4(manifest.id)));
}

bool manifestIdLooksLikeGemma4(String id) {
  final normalized = id.toLowerCase().replaceAll('_', '-');
  return normalized.startsWith('gemma4') || normalized.startsWith('gemma-4');
}

class LocalModelStore {
  LocalModelStore({required this.registry, LocalModelsSdkPaths? paths})
    : paths = paths ?? LocalModelsSdkPaths.forCurrentUser();

  final ModelRegistry registry;
  final LocalModelsSdkPaths paths;

  Future<List<InstalledModel>> listInstalledModels() async {
    await paths.ensureCreated();
    final discovered = <InstalledModel>[];
    await for (final entity in paths.modelsDirectory.list()) {
      if (entity is! Directory) {
        continue;
      }
      final sizeBytes = await directorySizeBytes(entity);
      final metadataFile = File(p.join(entity.path, installMetadataFileName));
      if (metadataFile.existsSync()) {
        final decoded =
            jsonDecode(await metadataFile.readAsString())
                as Map<String, dynamic>;
        final manifest = manifestWithRegistryRuntimeGapFill(
          primary: LocalModelManifest.fromJsonMap(
            Map<String, Object?>.from(decoded['manifest'] as Map),
          ),
          registry: registry,
        );
        discovered.add(
          InstalledModel(
            manifest: manifest,
            directory: entity,
            sourceLabel: decoded['sourceLabel'] as String? ?? 'Unknown',
            installedAt:
                DateTime.tryParse(decoded['installedAt'] as String? ?? '') ??
                DateTime.now(),
            metadataUpdatedAt: DateTime.tryParse(
              decoded['metadataUpdatedAt'] as String? ?? '',
            ),
            sizeBytes: sizeBytes,
          ),
        );
        continue;
      }

      final manifest = firstWhereOrNull(
        registry.manifests,
        (item) => item.id == p.basename(entity.path),
      );
      if (manifest != null) {
        discovered.add(
          InstalledModel(
            manifest: manifestWithRegistryRuntimeGapFill(
              primary: manifest,
              registry: registry,
            ),
            directory: entity,
            sourceLabel: 'Unknown',
            installedAt: (await entity.stat()).modified,
            sizeBytes: sizeBytes,
          ),
        );
      }
    }
    discovered.sort(
      (left, right) =>
          left.manifest.displayName.compareTo(right.manifest.displayName),
    );
    return List<InstalledModel>.unmodifiable(discovered);
  }

  Future<InstalledModel?> installedModelById(String id) async {
    return firstWhereOrNull(
      await listInstalledModels(),
      (model) => model.manifest.id == id,
    );
  }

  Future<void> deleteInstalledModel(InstalledModel model) async {
    if (model.directory.existsSync()) {
      await model.directory.delete(recursive: true);
    }
  }

  Future<void> writeInstallMetadata(
    Directory modelDirectory,
    LocalModelManifest manifest, {
    required String sourceLabel,
    DateTime? installedAt,
    DateTime? metadataUpdatedAt,
  }) async {
    await modelDirectory.create(recursive: true);
    final metadataFile = File(
      p.join(modelDirectory.path, installMetadataFileName),
    );
    final now = DateTime.now();
    final payload = <String, Object?>{
      'sourceLabel': sourceLabel,
      'installedAt': (installedAt ?? now).toIso8601String(),
      'metadataUpdatedAt': (metadataUpdatedAt ?? now).toIso8601String(),
      'manifest': manifest.toJson(),
    };
    await metadataFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }
}

LocalModelManifest manifestWithRegistryRuntimeGapFill({
  required LocalModelManifest primary,
  required ModelRegistry registry,
}) {
  final reg = firstWhereOrNull(registry.manifests, (m) => m.id == primary.id);
  if (reg == null) {
    return primary;
  }
  final rc = _runtimeConfigGapFill(
    primary: primary.runtimeConfig,
    gapFill: reg.runtimeConfig,
  );
  if (identical(rc, primary.runtimeConfig)) {
    return primary;
  }
  return LocalModelManifest(
    id: primary.id,
    displayName: primary.displayName,
    description: primary.description,
    runtimeAdapter: primary.runtimeAdapter,
    tasks: primary.tasks,
    source: primary.source,
    packaging: primary.packaging,
    requirements: primary.requirements,
    capabilities: primary.capabilities,
    modelCard: primary.modelCard,
    runtimeConfig: rc,
  );
}

ModelRuntimeConfig _runtimeConfigGapFill({
  required ModelRuntimeConfig primary,
  required ModelRuntimeConfig gapFill,
}) {
  if (gapFill.isEmpty) {
    return primary;
  }
  final defaults = primary.defaultParameters.isNotEmpty
      ? primary.defaultParameters
      : gapFill.defaultParameters;
  final voices = primary.voices.isNotEmpty ? primary.voices : gapFill.voices;
  final output = primary.output.isNotEmpty ? primary.output : gapFill.output;
  final extra = <String, Object?>{...gapFill.extra, ...primary.extra};
  return ModelRuntimeConfig(
    defaultParameters: defaults,
    parameterSchema: primary.parameterSchema.isNotEmpty
        ? primary.parameterSchema
        : gapFill.parameterSchema,
    voices: voices,
    output: output,
    extra: extra,
  );
}

Future<int> directorySizeBytes(Directory directory) async {
  var total = 0;
  if (!directory.existsSync()) {
    return total;
  }
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) {
      continue;
    }
    try {
      total += await entity.length();
    } on FileSystemException {
      continue;
    }
  }
  return total;
}

String sanitizeId(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
}

String formatBytes(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  final precision = value >= 10 || unitIndex == 0 ? 0 : 1;
  var formatted = value.toStringAsFixed(precision);
  if (formatted.endsWith('.0')) {
    formatted = formatted.substring(0, formatted.length - 2);
  }
  return '$formatted ${units[unitIndex]}';
}

T? firstWhereOrNull<T>(Iterable<T> items, bool Function(T item) test) {
  for (final item in items) {
    if (test(item)) {
      return item;
    }
  }
  return null;
}

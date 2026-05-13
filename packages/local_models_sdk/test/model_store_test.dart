import 'dart:io';

import 'package:local_models_sdk/local_models_sdk.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _manifest = LocalModelManifest(
  id: 'test-model',
  displayName: 'Test Model',
  description: 'fixture',
  runtimeAdapter: RuntimeAdapter.mlxLm,
  tasks: [ModelTask.chat],
  source: ModelSource(
    provider: 'huggingface',
    repo: 'example/test-model',
    revision: 'main',
    license: 'mit',
  ),
  packaging: PackagingSpec(
    releaseTag: 'v1',
    archiveName: 'test.tar',
    chunkSizeBytes: 1,
    assetPrefix: 'test',
  ),
  requirements: SystemRequirements(
    platform: 'macos-apple-silicon',
    minMemoryGb: 1,
    recommendedMemoryGb: 2,
    notes: [],
  ),
  capabilities: CapabilitySpec(
    audioInput: false,
    audioOutput: false,
    toolCalling: true,
  ),
);

void main() {
  test('LocalModelStore lists installed model metadata headlessly', () async {
    final tmp = await Directory.systemTemp.createTemp('flm-sdk-store-test');
    addTearDown(() async {
      if (tmp.existsSync()) {
        await tmp.delete(recursive: true);
      }
    });

    final paths = LocalModelsSdkPaths(baseDirectory: tmp);
    final registry = ModelRegistry([_manifest]);
    final store = LocalModelStore(registry: registry, paths: paths);
    final modelDir = Directory(
      p.join(paths.modelsDirectory.path, _manifest.id),
    );
    await modelDir.create(recursive: true);
    await File(p.join(modelDir.path, 'weights.bin')).writeAsString('abc');
    await store.writeInstallMetadata(
      modelDir,
      _manifest,
      sourceLabel: 'test',
      installedAt: DateTime.utc(2026, 1, 1),
    );

    final models = await store.listInstalledModels();

    expect(models, hasLength(1));
    expect(models.single.manifest.id, _manifest.id);
    expect(models.single.textPromptSupported, isTrue);
    expect(models.single.sizeBytes, greaterThan(0));
  });

  test('download task record round-trips JSON', () {
    final record =
        DownloadTaskRecord(
            id: 'd1',
            title: 'Download',
            sourceKind: DownloadSourceKind.huggingFace,
            modelId: _manifest.id,
            sourceLabel: 'HF',
            stageDirectory: Directory('/tmp/stage'),
            files: [
              RemoteFileDescriptor(
                relativePath: 'a.bin',
                downloadUri: Uri.parse('https://example.com/a.bin'),
                sizeBytes: 3,
                sha256: 'abc',
              ),
            ],
            manifest: _manifest,
          )
          ..downloadedBytes = 1
          ..totalBytes = 3;

    final decoded = DownloadTaskRecord.fromJsonMap(record.toJson());

    expect(decoded.id, record.id);
    expect(decoded.files.single.relativePath, 'a.bin');
    expect(decoded.manifest.id, _manifest.id);
  });
}

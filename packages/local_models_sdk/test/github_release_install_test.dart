import 'dart:convert';
import 'dart:io';

import 'package:local_models_core/local_models_core.dart';
import 'package:local_models_sdk/local_models_sdk.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _registryYaml = '''
id: gh-rel-test-model
display_name: Test
description: test
runtime_adapter: mlx_audio
tasks:
  - text_to_speech
source:
  provider: huggingface
  repo: test/repo
  revision: main
  license: mit
packaging:
  release_tag: model-gh-rel-test-model
  archive_name: gh-rel-test-model.tar
  chunk_size_bytes: 1000
  asset_prefix: gh-rel-test-model
requirements:
  platform: macos-apple-silicon
  min_memory_gb: 0
  recommended_memory_gb: 0
  notes: []
capabilities:
  audio_input: false
  audio_output: true
  tool_calling: false
default_parameters: {}
parameter_schema: {}
voices: []
output: {}
extra: {}
''';

void main() {
  test('installGitHubReleaseFromStageDirectory extracts tarball', () async {
    final temp = await Directory.systemTemp.createTemp('flm-gh-rel-');
    addTearDown(() async {
      if (temp.existsSync()) {
        await temp.delete(recursive: true);
      }
    });

    const modelId = 'gh-rel-test-model';
    final registryDir =
        Directory(p.join(temp.path, 'registry', 'models'))..createSync(recursive: true);
    File(p.join(registryDir.path, '$modelId.yaml')).writeAsStringSync(
      _registryYaml,
    );

    final registry = await ModelRegistry.loadDirectory(registryDir.path);
    final manifest = registry.byId(modelId);
    final base = Directory(p.join(temp.path, 'flm_base'));
    final store = LocalModelStore(
      registry: registry,
      paths: LocalModelsSdkPaths(baseDirectory: base),
    );

    final payloadRoot = Directory(p.join(temp.path, 'payload', modelId))
      ..createSync(recursive: true);
    File(p.join(payloadRoot.path, 'weights.txt')).writeAsStringSync('ok');

    final tarPath = p.join(temp.path, '$modelId.tar');
    final tarResult = await Process.run(
      'tar',
      ['-cf', tarPath, '-C', p.dirname(payloadRoot.path), modelId],
    );
    expect(tarResult.exitCode, 0, reason: tarResult.stderr.toString());

    final stage = Directory(p.join(temp.path, 'stage'))..createSync();
    final partName = '$modelId.part-000';
    await File(tarPath).copy(p.join(stage.path, partName));

    final meta = {
      'archive_name': '$modelId.tar',
      'parts': [
        {'file_name': partName},
      ],
    };
    File(p.join(stage.path, 'release_metadata.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(meta),
    );

    final installed = await installGitHubReleaseFromStageDirectory(
      store: store,
      stageDirectory: stage,
      baseManifest: manifest,
      sourceLabel: 'test',
    );

    expect(installed.manifest.id, modelId);
    expect(
      File(p.join(installed.directory.path, 'weights.txt')).readAsStringSync(),
      'ok',
    );
    expect(
      File(
        p.join(installed.directory.path, installMetadataFileName),
      ).existsSync(),
      isTrue,
    );
  });
}

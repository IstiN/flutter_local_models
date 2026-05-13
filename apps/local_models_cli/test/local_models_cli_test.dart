import 'dart:io';
import 'dart:convert';

import 'package:local_models_cli/local_models_cli.dart';
import 'package:local_models_core/local_models_core.dart';
import 'package:local_models_sdk/local_models_sdk.dart' as sdk;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _manifest = '''
id: qwen3-8b-4bit
display_name: Qwen3 8B 4bit
description: General-purpose chat and coding model.
runtime_adapter: mlx_lm
tasks:
  - chat
  - code
source:
  provider: huggingface
  repo: mlx-community/Qwen3-8B-4bit
  revision: main
  license: apache-2.0
packaging:
  release_tag: model-qwen3-8b-4bit
  archive_name: qwen3-8b-4bit.tar
  chunk_size_bytes: 1900000000
  asset_prefix: qwen3-8b-4bit
requirements:
  platform: macos-apple-silicon
  min_memory_gb: 16
  recommended_memory_gb: 24
  notes:
    - Fast text model
capabilities:
  audio_input: false
  audio_output: false
  tool_calling: true
''';

void main() {
  test('registry list prints available manifests', () async {
    final temp = await Directory.systemTemp.createTemp('local-models-cli-');
    addTearDown(() => temp.delete(recursive: true));
    final registry = Directory(p.join(temp.path, 'registry', 'models'))
      ..createSync(recursive: true);
    File(p.join(registry.path, 'qwen3.yaml')).writeAsStringSync(_manifest);

    final output = StringBuffer();
    final cli = LocalModelsCli();
    final code = await cli.run(
      ['registry', 'list', '--dir', registry.path],
      out: output,
      err: StringBuffer(),
      currentDirectory: temp.path,
    );

    expect(code, 0);
    expect(output.toString(), contains('qwen3-8b-4bit'));
    expect(output.toString(), contains('model-qwen3-8b-4bit'));
  });

  test('registry show prints manifest details', () async {
    final temp = await Directory.systemTemp.createTemp('local-models-cli-');
    addTearDown(() => temp.delete(recursive: true));
    final registry = Directory(p.join(temp.path, 'registry', 'models'))
      ..createSync(recursive: true);
    File(p.join(registry.path, 'qwen3.yaml')).writeAsStringSync(_manifest);

    final output = StringBuffer();
    final cli = LocalModelsCli();
    final code = await cli.run(
      ['registry', 'show', 'qwen3-8b-4bit', '--dir', registry.path],
      out: output,
      err: StringBuffer(),
      currentDirectory: temp.path,
    );

    expect(code, 0);
    expect(output.toString(), contains('name: Qwen3 8B 4bit'));
    expect(output.toString(), contains('chunks: qwen3-8b-4bit.part-000'));
  });

  test(
    'models list reads installed models through headless SDK store',
    () async {
      final temp = await Directory.systemTemp.createTemp('local-models-cli-');
      addTearDown(() => temp.delete(recursive: true));
      final registry = Directory(p.join(temp.path, 'registry', 'models'))
        ..createSync(recursive: true);
      File(p.join(registry.path, 'qwen3.yaml')).writeAsStringSync(_manifest);

      final sdkPaths = sdk.LocalModelsSdkPaths.forCurrentUser(
        homeDirectory: temp.path,
      );
      final modelDir = Directory(
        p.join(sdkPaths.modelsDirectory.path, 'qwen3-8b-4bit'),
      )..createSync(recursive: true);
      File(p.join(modelDir.path, 'weights.bin')).writeAsStringSync('abc');
      final manifest = LocalModelManifest.fromYaml(_manifest);
      File(
        p.join(modelDir.path, sdk.installMetadataFileName),
      ).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'sourceLabel': 'test',
          'installedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          'manifest': manifest.toJson(),
        }),
      );

      final output = StringBuffer();
      final cli = LocalModelsCli();
      final code = await cli.run(
        [
          'models',
          'list',
          '--dir',
          registry.path,
          '--base-dir',
          sdkPaths.baseDirectory.path,
        ],
        out: output,
        err: StringBuffer(),
        currentDirectory: temp.path,
      );

      expect(code, 0);
      expect(output.toString(), contains('qwen3-8b-4bit'));
      expect(output.toString(), contains(modelDir.path));
    },
  );
}

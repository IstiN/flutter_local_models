import 'dart:io';

import 'package:local_models_core/local_models_core.dart';
import 'package:local_models_sdk/local_models_sdk.dart' as sdk;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final cliRoot = Directory.current;
  final registryDir = Directory(
    p.normalize(p.join(cliRoot.path, '..', '..', 'registry', 'models')),
  );

  test('CLI process lists already installed models from SDK store', () async {
    final installed = await _installedModels(registryDir);
    if (installed.isEmpty) {
      markTestSkipped(
        'No installed models found in ${_sdkPaths().modelsDirectory.path}',
      );
    }

    final result = await _runCli([
      'models',
      'list',
      '--dir',
      registryDir.path,
      '--base-dir',
      _sdkPaths().baseDirectory.path,
    ]);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final stdoutText = result.stdout as String;
    expect(stdoutText, contains(installed.first.manifest.id));
    expect(stdoutText, contains(installed.first.directory.path));
  });

  test('CLI process shows installed Gemma4 E2B when downloaded', () async {
    await _expectInstalledModelShow(
      registryDir: registryDir,
      modelId: 'gemma4-e2b-it-4bit',
    );
  });

  test('CLI process shows installed Qwen3 8B when downloaded', () async {
    await _expectInstalledModelShow(
      registryDir: registryDir,
      modelId: 'qwen3-8b-4bit',
    );
  });
}

Future<void> _expectInstalledModelShow({
  required Directory registryDir,
  required String modelId,
}) async {
  final installed = await _installedModels(registryDir);
  final model = sdk.firstWhereOrNull(
    installed,
    (item) => item.manifest.id == modelId,
  );
  if (model == null) {
    markTestSkipped('Installed model not found: $modelId');
    return;
  }

  final result = await _runCli([
    'models',
    'show',
    modelId,
    '--dir',
    registryDir.path,
    '--base-dir',
    _sdkPaths().baseDirectory.path,
  ]);

  expect(result.exitCode, 0, reason: result.stderr as String);
  final stdoutText = result.stdout as String;
  expect(stdoutText, contains('id: $modelId'));
  expect(stdoutText, contains('path: ${model.directory.path}'));
  expect(
    stdoutText,
    contains('runtime: ${model.manifest.runtimeAdapter.name}'),
  );
}

Future<List<sdk.InstalledModel>> _installedModels(Directory registryDir) async {
  final registry = await ModelRegistry.loadDirectory(registryDir.path);
  return sdk.LocalModelStore(
    registry: registry,
    paths: _sdkPaths(),
  ).listInstalledModels();
}

sdk.LocalModelsSdkPaths _sdkPaths() => sdk.LocalModelsSdkPaths.forCurrentUser();

Future<ProcessResult> _runCli(List<String> args) {
  return Process.run(Platform.resolvedExecutable, [
    'run',
    'local_models_cli',
    ...args,
  ], workingDirectory: Directory.current.path);
}

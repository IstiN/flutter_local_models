library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:local_models_core/local_models_core.dart';
import 'package:local_models_sdk/local_models_sdk.dart' as sdk;

class LocalModelsCli {
  Future<int> run(
    List<String> arguments, {
    StringSink? out,
    StringSink? err,
    String? currentDirectory,
  }) async {
    final output = out ?? stdout;
    final errors = err ?? stderr;
    final cwd = currentDirectory ?? Directory.current.path;

    final parser = ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption(
        'dir',
        help: 'Registry directory.',
        defaultsTo: resolveDefaultRegistryPath(cwd),
      )
      ..addOption('base-dir', help: 'Local models SDK base directory.')
      ..addOption(
        'github-owner',
        help: 'GitHub owner for models install (GitHub Releases).',
        defaultsTo: 'IstiN',
      )
      ..addOption(
        'github-repo',
        help: 'GitHub repository for models install (GitHub Releases).',
        defaultsTo: 'flutter_local_models',
      )
      ..addOption(
        'github-token',
        help:
            'Optional GitHub token for API/download rate limits. '
            'Defaults to GITHUB_TOKEN env when unset.',
        defaultsTo: '',
      );

    if (arguments.isEmpty ||
        arguments.first == 'help' ||
        arguments.first == '--help') {
      _writeUsage(output, parser);
      return 0;
    }

    final command = arguments.first;
    final rest = arguments.skip(1).toList(growable: false);

    switch (command) {
      case 'doctor':
        output.writeln('flutter_local_models CLI doctor');
        output.writeln('cwd: $cwd');
        output.writeln('registry: ${resolveDefaultRegistryPath(cwd)}');
        output.writeln('platform: ${Platform.operatingSystem}');
        return 0;
      case 'registry':
        return _runRegistry(rest, parser, output, errors);
      case 'models':
        return _runModels(rest, parser, output, errors);
      default:
        errors.writeln('Unknown command: $command');
        _writeUsage(errors, parser);
        return 64;
    }
  }

  Future<int> _runModels(
    List<String> arguments,
    ArgParser parser,
    StringSink out,
    StringSink err,
  ) async {
    if (arguments.isEmpty) {
      err.writeln('Missing models subcommand. Use list, show, or install.');
      return 64;
    }

    final subcommand = arguments.first;
    final rest = arguments.skip(1).toList(growable: false);
    late final ArgResults results;
    try {
      results = parser.parse(rest);
    } on FormatException catch (error) {
      err.writeln(error.message);
      return 64;
    }

    final registryPath = results['dir'] as String;
    late final ModelRegistry registry;
    try {
      registry = await ModelRegistry.loadDirectory(registryPath);
    } on FileSystemException catch (error) {
      err.writeln(
        'Failed to load registry from $registryPath: ${error.message}',
      );
      return 66;
    }

    final baseDir = results['base-dir'] as String?;
    final store = sdk.LocalModelStore(
      registry: registry,
      paths: baseDir == null || baseDir.trim().isEmpty
          ? null
          : sdk.LocalModelsSdkPaths(baseDirectory: Directory(baseDir)),
    );
    final models = await store.listInstalledModels();
    switch (subcommand) {
      case 'list':
        for (final model in models) {
          out.writeln(
            '${model.manifest.id}\t${model.manifest.displayName}\t${sdk.formatBytes(model.sizeBytes)}\t${model.directory.path}',
          );
        }
        return 0;
      case 'show':
        final ids = rest.where((item) => !item.startsWith('-')).toList();
        if (ids.isEmpty) {
          err.writeln('Missing model id for models show.');
          return 64;
        }
        final id = ids.first;
        sdk.InstalledModel? model;
        for (final item in models) {
          if (item.manifest.id == id) {
            model = item;
            break;
          }
        }
        if (model == null) {
          err.writeln('Installed model not found: $id');
          return 2;
        }
        out.writeln('id: ${model.manifest.id}');
        out.writeln('name: ${model.manifest.displayName}');
        out.writeln('runtime: ${model.manifest.runtimeAdapter.name}');
        out.writeln(
          'tasks: ${model.manifest.tasks.map(modelTaskToString).join(', ')}',
        );
        out.writeln('size: ${sdk.formatBytes(model.sizeBytes)}');
        out.writeln('path: ${model.directory.path}');
        out.writeln('source: ${model.sourceLabel}');
        out.writeln('installedAt: ${model.installedAt.toIso8601String()}');
        return 0;
      case 'install':
        final ids = rest.where((item) => !item.startsWith('-')).toList();
        if (ids.isEmpty) {
          err.writeln('Missing model id for models install.');
          return 64;
        }
        final id = ids.first;
        late final LocalModelManifest manifest;
        try {
          manifest = registry.byId(id);
        } on StateError catch (error) {
          err.writeln(error.message);
          return 2;
        }
        final rawToken = (results['github-token'] as String).trim();
        final envToken = Platform.environment['GITHUB_TOKEN'] ?? '';
        final githubToken =
            rawToken.isEmpty ? envToken.trim() : rawToken;
        final githubOwner = results['github-owner'] as String;
        final githubRepo = results['github-repo'] as String;
        out.writeln(
          'Installing ${manifest.id} from $githubOwner/$githubRepo '
          'release ${manifest.packaging.releaseTag}…',
        );
        try {
          final manager = sdk.LocalModelDownloadManager(
            store: store,
            githubToken: githubToken,
          );
          final installed = await manager.downloadAndInstallFromGitHubRelease(
            manifest: manifest,
            githubOwner: githubOwner,
            githubRepository: githubRepo,
          );
          out.writeln('Installed: ${installed.directory.path}');
        } catch (error) {
          err.writeln('$error');
          return 1;
        }
        return 0;
      default:
        err.writeln('Unknown models subcommand: $subcommand');
        return 64;
    }
  }

  Future<int> _runRegistry(
    List<String> arguments,
    ArgParser parser,
    StringSink out,
    StringSink err,
  ) async {
    if (arguments.isEmpty) {
      err.writeln('Missing registry subcommand. Use list or show.');
      return 64;
    }

    final subcommand = arguments.first;
    final rest = arguments.skip(1).toList(growable: false);
    late final ArgResults results;
    try {
      results = parser.parse(rest);
    } on FormatException catch (error) {
      err.writeln(error.message);
      return 64;
    }

    final registryPath = results['dir'] as String;
    late final ModelRegistry registry;
    try {
      registry = await ModelRegistry.loadDirectory(registryPath);
    } on FileSystemException catch (error) {
      err.writeln(
        'Failed to load registry from $registryPath: ${error.message}',
      );
      return 66;
    }

    switch (subcommand) {
      case 'list':
        for (final manifest in registry.manifests) {
          out.writeln(
            '${manifest.id}\t${manifest.displayName}\t${manifest.packaging.releaseTag}',
          );
        }
        return 0;
      case 'show':
        if (rest.where((item) => !item.startsWith('-')).isEmpty) {
          err.writeln('Missing manifest id for registry show.');
          return 64;
        }
        final manifestId = arguments[1];
        try {
          final manifest = registry.byId(manifestId);
          final plan = ReleaseBundlePlan.fromManifest(
            manifest,
            sampleChunkCount: 2,
          );
          out.writeln('id: ${manifest.id}');
          out.writeln('name: ${manifest.displayName}');
          out.writeln('runtime: ${manifest.runtimeAdapter.name}');
          out.writeln(
            'tasks: ${manifest.tasks.map(modelTaskToString).join(', ')}',
          );
          out.writeln(
            'source: ${manifest.source.repo}@${manifest.source.revision}',
          );
          out.writeln('release: ${plan.releaseTag}');
          out.writeln('archive: ${plan.archiveName}');
          out.writeln(
            'chunks: ${plan.sampleChunks.map((chunk) => chunk.fileName).join(', ')}',
          );
          return 0;
        } on StateError catch (error) {
          err.writeln(error.message);
          return 2;
        }
      default:
        err.writeln('Unknown registry subcommand: $subcommand');
        return 64;
    }
  }

  void _writeUsage(StringSink sink, ArgParser parser) {
    sink.writeln('Usage: local_models_cli <command> [arguments]');
    sink.writeln('');
    sink.writeln('Commands:');
    sink.writeln('  doctor');
    sink.writeln('  models list [--dir <registry path>] [--base-dir <path>]');
    sink.writeln(
      '  models install <id> [--dir …] [--base-dir …] '
      '[--github-owner …] [--github-repo …] [--github-token …]',
    );
    sink.writeln('  registry list [--dir <path>]');
    sink.writeln('  registry show <id> [--dir <path>]');
    sink.writeln('');
    sink.writeln(parser.usage);
  }
}

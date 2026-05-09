library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:local_models_core/local_models_core.dart';

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
      default:
        errors.writeln('Unknown command: $command');
        _writeUsage(errors, parser);
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
    sink.writeln('  registry list [--dir <path>]');
    sink.writeln('  registry show <id> [--dir <path>]');
    sink.writeln('');
    sink.writeln(parser.usage);
  }
}

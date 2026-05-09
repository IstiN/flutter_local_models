import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_models_core/local_models_core.dart';
import 'package:local_models_flutter/local_models_flutter.dart';

void main() {
  runApp(const StudioApp());
}

class StudioSnapshot {
  const StudioSnapshot({required this.registry, required this.runtimeSummary});

  final ModelRegistry registry;
  final NativeRuntimeSummary runtimeSummary;
}

class StudioApp extends StatelessWidget {
  const StudioApp({super.key, this.registryLoader, this.runtimeSummaryLoader});

  final Future<ModelRegistry> Function()? registryLoader;
  final Future<NativeRuntimeSummary> Function()? runtimeSummaryLoader;

  Future<ModelRegistry> _loadRegistry() async {
    if (registryLoader != null) {
      return registryLoader!();
    }

    final overrideDirectory = Platform.environment['LOCAL_MODELS_REGISTRY_DIR'];
    if (overrideDirectory != null &&
        Directory(overrideDirectory).existsSync()) {
      return ModelRegistry.loadDirectory(overrideDirectory);
    }

    final catalogJson = await rootBundle.loadString('assets/catalog.json');
    return ModelRegistry.fromCatalogJson(catalogJson);
  }

  Future<NativeRuntimeSummary> _loadRuntimeSummary() async {
    if (runtimeSummaryLoader != null) {
      return runtimeSummaryLoader!();
    }
    return LocalModelsFlutter().getRuntimeSummary();
  }

  Future<StudioSnapshot> _loadSnapshot() async {
    final registry = await _loadRegistry();
    final summary = await _loadRuntimeSummary();
    return StudioSnapshot(registry: registry, runtimeSummary: summary);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Local Models Studio',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4C6FFF)),
        useMaterial3: true,
      ),
      home: FutureBuilder<StudioSnapshot>(
        future: _loadSnapshot(),
        builder: (context, snapshot) {
          return StudioHomePage(snapshot: snapshot);
        },
      ),
    );
  }
}

class StudioHomePage extends StatelessWidget {
  const StudioHomePage({super.key, required this.snapshot});

  final AsyncSnapshot<StudioSnapshot> snapshot;

  @override
  Widget build(BuildContext context) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (snapshot.hasError) {
      return Scaffold(
        appBar: AppBar(title: const Text('Local Models Studio')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Failed to load studio data: ${snapshot.error}'),
        ),
      );
    }

    final data = snapshot.requireData;
    final runtime = data.runtimeSummary;

    return Scaffold(
      appBar: AppBar(title: const Text('Local Models Studio')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Runtime',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('Bridge: ${runtime.bridgeVersion}'),
                    Text('Platform: ${runtime.platform}'),
                    Text(
                      'Metal available: ${runtime.metalAvailable ? 'yes' : 'no'}',
                    ),
                    Text('FFI enabled: ${runtime.ffiEnabled ? 'yes' : 'no'}'),
                    if (runtime.hasError) ...[
                      const SizedBox(height: 8),
                      Text(
                        runtime.errorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Catalog (${data.registry.manifests.length})',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                itemCount: data.registry.manifests.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final manifest = data.registry.manifests[index];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            manifest.displayName,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(manifest.description),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: manifest.tasks
                                .map(
                                  (task) => Chip(
                                    label: Text(modelTaskToString(task)),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                          const SizedBox(height: 12),
                          Text('HF: ${manifest.source.repo}'),
                          Text('Release: ${manifest.packaging.releaseTag}'),
                          Text(
                            'Minimum RAM: ${manifest.requirements.minMemoryGb} GB',
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

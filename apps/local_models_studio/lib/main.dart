import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_models_core/local_models_core.dart';
import 'package:local_models_flutter/local_models_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

import 'studio_services.dart';

void main() {
  runApp(const StudioApp());
}

typedef StudioControllerFactory =
    StudioController Function(
      ModelRegistry registry,
      NativeRuntimeSummary runtimeSummary,
    );

class StudioSnapshot {
  const StudioSnapshot({required this.registry, required this.runtimeSummary});

  final ModelRegistry registry;
  final NativeRuntimeSummary runtimeSummary;
}

class StudioApp extends StatelessWidget {
  const StudioApp({
    super.key,
    this.registryLoader,
    this.runtimeSummaryLoader,
    this.controllerFactory,
  });

  final Future<ModelRegistry> Function()? registryLoader;
  final Future<NativeRuntimeSummary> Function()? runtimeSummaryLoader;
  final StudioControllerFactory? controllerFactory;

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
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
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

          return StudioShell(
            snapshot: snapshot.requireData,
            controllerFactory: controllerFactory,
          );
        },
      ),
    );
  }
}

class StudioShell extends StatefulWidget {
  const StudioShell({
    super.key,
    required this.snapshot,
    this.controllerFactory,
  });

  final StudioSnapshot snapshot;
  final StudioControllerFactory? controllerFactory;

  @override
  State<StudioShell> createState() => _StudioShellState();
}

class _StudioShellState extends State<StudioShell> {
  late final StudioController controller;
  late final TextEditingController hfTokenController;
  late final TextEditingController customRepoController;
  late final TextEditingController chatPromptController;
  late final AudioRecorder audioRecorder;
  InstalledModel? selectedTestModel;
  String? selectedAudioPath;
  bool audioInputMode = false;
  bool recordingAudio = false;
  bool testBusy = false;
  String? testErrorMessage;
  bool obscureHfToken = true;

  @override
  void initState() {
    super.initState();
    controller =
        widget.controllerFactory?.call(
          widget.snapshot.registry,
          widget.snapshot.runtimeSummary,
        ) ??
        StudioController(
          registry: widget.snapshot.registry,
          runtimeSummary: widget.snapshot.runtimeSummary,
        );
    hfTokenController = TextEditingController(text: controller.hfToken);
    customRepoController = TextEditingController(
      text: controller.customHfRepoId,
    );
    chatPromptController = TextEditingController();
    audioRecorder = AudioRecorder();
    controller.addListener(_handleControllerUpdate);
    unawaited(controller.initialize());
  }

  @override
  void dispose() {
    controller.removeListener(_handleControllerUpdate);
    hfTokenController.dispose();
    customRepoController.dispose();
    chatPromptController.dispose();
    audioRecorder.dispose();
    super.dispose();
  }

  void _handleControllerUpdate() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Local Models Studio'),
          actions: [
            IconButton(
              tooltip: 'Refresh sources',
              onPressed: controller.loadingSources
                  ? null
                  : () => _runAction(controller.refreshSources),
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Catalog', icon: Icon(Icons.inventory_2_outlined)),
              Tab(text: 'Downloads', icon: Icon(Icons.download_outlined)),
              Tab(text: 'Test', icon: Icon(Icons.play_circle_outline)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildCatalogTab(context),
            _buildDownloadsTab(context),
            _buildTestTab(context),
          ],
        ),
      ),
    );
  }

  Widget _buildCatalogTab(BuildContext context) {
    return RefreshIndicator(
      onRefresh: controller.refreshSources,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildRuntimeCard(context),
          const SizedBox(height: 16),
          _buildSourceControlCard(context),
          if (controller.sourceErrorMessage != null) ...[
            const SizedBox(height: 16),
            _buildErrorCard(
              title: 'Source refresh error',
              message: controller.sourceErrorMessage!,
            ),
          ],
          const SizedBox(height: 16),
          _buildGitHubReleaseSection(context),
          const SizedBox(height: 16),
          Text(
            'Manifest Catalog (${controller.registry.manifests.length})',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          ...controller.registry.manifests.map(
            (manifest) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _buildManifestCard(context, manifest),
            ),
          ),
          if (controller.customHfRepoId.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Custom Hugging Face Repo',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            _buildCustomRepoCard(context),
          ],
        ],
      ),
    );
  }

  Widget _buildDownloadsTab(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Transfers', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (controller.downloads.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No downloads yet. Start a Hugging Face or GitHub Release download from the Catalog tab.',
              ),
            ),
          )
        else
          ...controller.downloads.map(
            (task) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _buildDownloadCard(task),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          'Installed Models (${controller.installedModels.length})',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        if (controller.installedModels.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No local models installed yet. Once a download finishes, it will appear here.',
              ),
            ),
          )
        else
          ...controller.installedModels.map(
            (model) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _buildInstalledModelCard(context, model),
            ),
          ),
      ],
    );
  }

  Widget _buildTestTab(BuildContext context) {
    final installedModels = controller.installedModels;
    final selectedModel = installedModels.contains(selectedTestModel)
        ? selectedTestModel
        : installedModels.isEmpty
        ? null
        : installedModels.first;
    final useAudioInput =
        selectedModel?.speechToTextSupported == true ||
        (selectedModel?.audioPromptSupported == true && audioInputMode);
    final canSendText =
        selectedModel?.textPromptSupported == true &&
        !useAudioInput &&
        chatPromptController.text.trim().isNotEmpty &&
        !testBusy;
    final canSendAudio =
        useAudioInput &&
        selectedAudioPath != null &&
        !recordingAudio &&
        !testBusy;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (installedModels.isEmpty)
                    const Text('No installed models yet.')
                  else
                    DropdownButtonFormField<InstalledModel>(
                      initialValue: selectedModel,
                      decoration: const InputDecoration(
                        labelText: 'Model',
                        border: OutlineInputBorder(),
                      ),
                      items: installedModels
                          .map(
                            (model) => DropdownMenuItem<InstalledModel>(
                              value: model,
                              child: Text(
                                '${model.manifest.displayName} (${_testModeLabel(model)})',
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        setState(() {
                          selectedTestModel = value;
                          selectedAudioPath = null;
                          audioInputMode =
                              value?.speechToTextSupported == true &&
                              value?.textPromptSupported != true;
                          testErrorMessage = null;
                        });
                        controller.clearChat();
                      },
                    ),
                  if (selectedModel?.audioPromptSupported == true &&
                      selectedModel?.textPromptSupported == true) ...[
                    const SizedBox(height: 12),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment<bool>(
                          value: false,
                          icon: Icon(Icons.chat_bubble_outline),
                          label: Text('Text'),
                        ),
                        ButtonSegment<bool>(
                          value: true,
                          icon: Icon(Icons.graphic_eq),
                          label: Text('Audio'),
                        ),
                      ],
                      selected: <bool>{audioInputMode},
                      onSelectionChanged: testBusy || recordingAudio
                          ? null
                          : (selection) {
                              setState(() {
                                audioInputMode = selection.first;
                                selectedAudioPath = null;
                                testErrorMessage = null;
                              });
                            },
                    ),
                  ],
                  if (selectedModel != null) ...[
                    const SizedBox(height: 12),
                    SelectableText(
                      'Path: ${selectedModel.directory.path}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (testErrorMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      testErrorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: controller.chatTurns.isEmpty
                ? const Card(
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Select an installed model, send text or audio, and the result will appear here.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: controller.chatTurns.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final turn = controller.chatTurns[index];
                      final alignment = turn.isUser
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start;
                      final color = turn.isUser
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest;
                      return Column(
                        crossAxisAlignment: alignment,
                        children: [
                          Text(turn.isUser ? 'You' : 'Model'),
                          const SizedBox(height: 4),
                          Container(
                            constraints: const BoxConstraints(maxWidth: 760),
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.all(12),
                            child: SelectableText(turn.message),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          const SizedBox(height: 16),
          if (useAudioInput && selectedModel != null)
            Column(
              children: [
                if (selectedModel.textPromptSupported) ...[
                  TextField(
                    controller: chatPromptController,
                    minLines: 2,
                    maxLines: 4,
                    onChanged: (_) => setState(() {}),
                    enabled: !testBusy,
                    decoration: const InputDecoration(
                      labelText: 'Audio prompt',
                      border: OutlineInputBorder(),
                      hintText: 'Ask what the model should do with the audio...',
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _buildAudioInputBar(selectedModel),
              ],
            )
          else
            TextField(
              controller: chatPromptController,
              minLines: 3,
              maxLines: 6,
              onChanged: (_) => setState(() {}),
              enabled: selectedModel?.textPromptSupported == true && !testBusy,
              decoration: InputDecoration(
                labelText: 'Message',
                border: const OutlineInputBorder(),
                hintText: selectedModel == null
                    ? 'Install a model first'
                    : selectedModel.textPromptSupported
                    ? 'Type a message for the selected model...'
                    : 'This installed model is not testable yet',
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              if (useAudioInput && selectedModel != null)
                FilledButton.icon(
                  onPressed: canSendAudio
                      ? () => _sendAudioToSelectedModel(selectedModel)
                      : null,
                  icon: testBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  label: Text(testBusy ? 'Running...' : 'Send Audio'),
                )
              else
                FilledButton.icon(
                  onPressed: canSendText
                      ? () => _sendPromptToSelectedModel(selectedModel!)
                      : null,
                  icon: testBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                  label: Text(testBusy ? 'Running...' : 'Send Message'),
                ),
              OutlinedButton.icon(
                onPressed: testBusy || controller.chatTurns.isEmpty
                    ? null
                    : controller.clearChat,
                icon: const Icon(Icons.clear_all),
                label: const Text('Clear'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAudioInputBar(InstalledModel model) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(recordingAudio ? Icons.mic : Icons.audio_file),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                recordingAudio
                    ? 'Recording...'
                    : selectedAudioPath == null
                    ? 'No audio selected'
                    : p.basename(selectedAudioPath!),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: testBusy
                  ? null
                  : recordingAudio
                  ? _stopAudioRecording
                  : _startAudioRecording,
              icon: Icon(recordingAudio ? Icons.stop : Icons.mic),
              label: Text(recordingAudio ? 'Stop' : 'Record'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: recordingAudio || testBusy ? null : _chooseAudioFile,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRuntimeCard(BuildContext context) {
    final runtime = controller.runtimeSummary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Runtime',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text('Bridge: ${runtime.bridgeVersion}'),
            Text('Platform: ${runtime.platform}'),
            Text('Metal available: ${runtime.metalAvailable ? 'yes' : 'no'}'),
            Text('FFI enabled: ${runtime.ffiEnabled ? 'yes' : 'no'}'),
            if (runtime.hasError) ...[
              const SizedBox(height: 8),
              Text(
                runtime.errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSourceControlCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Live Sources',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Browse the configured Hugging Face repos, inspect our GitHub releases, and test downloads with pause, resume, cancel, and delete.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: hfTokenController,
              obscureText: obscureHfToken,
              decoration: InputDecoration(
                labelText: 'HF token (optional)',
                border: const OutlineInputBorder(),
                helperText:
                    'Leave empty for public repos. Use a token for gated or private Hugging Face repos.',
                suffixIcon: IconButton(
                  onPressed: () {
                    setState(() => obscureHfToken = !obscureHfToken);
                  },
                  icon: Icon(
                    obscureHfToken ? Icons.visibility : Icons.visibility_off,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () {
                    controller.updateHfToken(hfTokenController.text);
                    _runAction(controller.refreshSources);
                  },
                  icon: const Icon(Icons.key),
                  label: const Text('Apply Token'),
                ),
                OutlinedButton.icon(
                  onPressed: controller.loadingSources
                      ? null
                      : () => _runAction(controller.refreshSources),
                  icon: const Icon(Icons.refresh),
                  label: Text(
                    controller.loadingSources ? 'Refreshing...' : 'Refresh All',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: customRepoController,
              decoration: const InputDecoration(
                labelText: 'Custom Hugging Face repo',
                hintText: 'mlx-community/Qwen3-8B-4bit',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () {
                    _runAction(
                      () => controller.loadCustomHuggingFaceRepo(
                        customRepoController.text,
                      ),
                    );
                  },
                  icon: const Icon(Icons.travel_explore),
                  label: const Text('Load HF Repo'),
                ),
                if (controller.customHfRepoDetails != null)
                  FilledButton.icon(
                    onPressed: () =>
                        _runAction(controller.startCustomHuggingFaceDownload),
                    icon: const Icon(Icons.download),
                    label: const Text('Download Custom Repo'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGitHubReleaseSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'GitHub Releases (${controller.githubReleases.length})',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        if (controller.githubReleases.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No GitHub releases are published yet for the current catalog.',
              ),
            ),
          )
        else
          ...controller.githubReleases.map(
            (release) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        release.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text('Tag: ${release.tagName}'),
                      Text('Assets: ${release.assets.length}'),
                      Text(
                        'Total asset size: ${formatBytes(release.assets.fold<int>(0, (sum, asset) => sum + asset.sizeBytes))}',
                      ),
                      if (release.manifest != null)
                        Text(
                          'Matches manifest: ${release.manifest!.displayName}',
                        ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          FilledButton.icon(
                            onPressed: release.hasBundleAssets
                                ? () => _runAction(
                                    () => controller.startGitHubReleaseDownload(
                                      release,
                                    ),
                                  )
                                : null,
                            icon: const Icon(Icons.download),
                            label: const Text('Download Release'),
                          ),
                          if (release.manifest != null &&
                              controller.installedModelForManifest(
                                    release.manifest!,
                                  ) !=
                                  null)
                            OutlinedButton.icon(
                              onPressed: () {
                                final installed = controller
                                    .installedModelForManifest(
                                      release.manifest!,
                                    );
                                if (installed != null) {
                                  _openModelInChat(installed, context);
                                }
                              },
                              icon: const Icon(Icons.chat),
                              label: const Text('Open in Chat'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildManifestCard(BuildContext context, LocalModelManifest manifest) {
    final release = controller.releaseForManifest(manifest);
    final installed = controller.installedModelForManifest(manifest);
    final hfDetails = controller.huggingFaceReposById[manifest.source.repo];
    final hfError = controller.huggingFaceErrorsById[manifest.source.repo];

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
              children: [
                ...manifest.tasks.map(
                  (task) => Chip(label: Text(modelTaskToString(task))),
                ),
                Chip(label: Text(manifest.runtimeAdapter.name)),
                Chip(
                  label: Text(
                    'Min RAM ${manifest.requirements.minMemoryGb} GB',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('HF repo: ${manifest.source.repo}'),
            if (hfDetails != null)
              Text(
                'HF files: ${hfDetails.files.length}${hfDetails.gated ? ' • gated' : ''}${hfDetails.pipelineTag != null ? ' • ${hfDetails.pipelineTag}' : ''}',
              ),
            if (hfError != null)
              Text(
                hfError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Text(
              release == null
                  ? 'GitHub release: not published yet'
                  : 'GitHub release: ${release.tagName}',
            ),
            if (installed != null) ...[
              const SizedBox(height: 8),
              Text('Installed: ${installed.directory.path}'),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () => _runAction(
                    () => controller.startManifestHuggingFaceDownload(manifest),
                  ),
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Download from HF'),
                ),
                OutlinedButton.icon(
                  onPressed: release == null
                      ? null
                      : () => _runAction(
                          () => controller.startGitHubReleaseDownload(release),
                        ),
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('Download Release'),
                ),
                if (installed != null)
                  OutlinedButton.icon(
                    onPressed: installed.chatSupported
                        ? () => _openModelInChat(installed, context)
                        : null,
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('Open in Chat'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomRepoCard(BuildContext context) {
    if (controller.customHfErrorMessage != null) {
      return _buildErrorCard(
        title: 'Custom HF repo error',
        message: controller.customHfErrorMessage!,
      );
    }

    final details = controller.customHfRepoDetails;
    if (details == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No custom repo loaded yet.'),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              details.repoId,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('Files: ${details.files.length}'),
            Text('Revision: ${details.revision}'),
            Text('Gated: ${details.gated ? 'yes' : 'no'}'),
            if (details.pipelineTag != null)
              Text('Pipeline: ${details.pipelineTag}'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () =>
                      _runAction(controller.startCustomHuggingFaceDownload),
                  icon: const Icon(Icons.download),
                  label: const Text('Download from HF'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadCard(DownloadTaskRecord task) {
    final progress = task.progress;
    final statusLabel = switch (task.status) {
      DownloadTaskStatus.queued => 'Queued',
      DownloadTaskStatus.running => 'Downloading',
      DownloadTaskStatus.paused => 'Paused',
      DownloadTaskStatus.canceled => 'Canceled',
      DownloadTaskStatus.installing => 'Installing',
      DownloadTaskStatus.completed => 'Installed',
      DownloadTaskStatus.failed => 'Failed',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(task.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Source: ${task.sourceLabel}'),
            Text('Status: $statusLabel'),
            if (task.totalBytes > 0)
              Text(
                '${formatBytes(task.downloadedBytes)} / ${formatBytes(task.totalBytes)}',
              )
            else
              Text('${formatBytes(task.downloadedBytes)} downloaded'),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
            if (task.errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                task.errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (task.installedPath != null) ...[
              const SizedBox(height: 12),
              SelectableText('Installed at: ${task.installedPath!}'),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: task.canPause
                      ? () => controller.pauseDownload(task)
                      : null,
                  icon: const Icon(Icons.pause),
                  label: const Text('Pause'),
                ),
                OutlinedButton.icon(
                  onPressed: task.canResume
                      ? () => controller.resumeDownload(task)
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume'),
                ),
                OutlinedButton.icon(
                  onPressed: task.canCancel
                      ? () => controller.cancelDownload(task)
                      : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Cancel'),
                ),
                TextButton.icon(
                  onPressed: task.canClear
                      ? () => controller.clearDownload(task)
                      : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Clear'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInstalledModelCard(BuildContext context, InstalledModel model) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              model.manifest.displayName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('Source: ${model.sourceLabel}'),
            Text('Runtime: ${model.manifest.runtimeAdapter.name}'),
            Text(
              'Tasks: ${model.manifest.tasks.map(modelTaskToString).join(', ')}',
            ),
            const SizedBox(height: 8),
            SelectableText(model.directory.path),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => _openModelInTest(model, context),
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Open in Test'),
                ),
                OutlinedButton.icon(
                  onPressed: () => controller.deleteInstalledModel(model),
                  icon: const Icon(Icons.delete_forever),
                  label: const Text('Delete Model'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard({required String title, required String message}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(message),
          ],
        ),
      ),
    );
  }

  void _openModelInChat(InstalledModel model, BuildContext context) {
    _openModelInTest(model, context);
  }

  void _openModelInTest(InstalledModel model, BuildContext context) {
    setState(() {
      selectedTestModel = model;
      selectedAudioPath = null;
      testErrorMessage = null;
    });
    controller.clearChat();
    DefaultTabController.of(context).animateTo(2);
  }

  Future<void> _chooseAudioFile() async {
    const audioTypeGroup = XTypeGroup(
      label: 'audio',
      extensions: <String>['wav', 'mp3', 'm4a', 'aac', 'flac', 'ogg'],
    );
    final file = await openFile(acceptedTypeGroups: <XTypeGroup>[audioTypeGroup]);
    if (file == null) {
      return;
    }
    setState(() => selectedAudioPath = file.path);
  }

  Future<void> _startAudioRecording() async {
    final hasPermission = await audioRecorder.hasPermission();
    if (!hasPermission) {
      setState(() => testErrorMessage = 'Microphone permission was denied.');
      return;
    }

    final directory = await Directory.systemTemp.createTemp('flm-recording-');
    final path = p.join(
      directory.path,
      'recording-${DateTime.now().millisecondsSinceEpoch}.m4a',
    );
    await audioRecorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );
    setState(() {
      selectedAudioPath = path;
      recordingAudio = true;
      testErrorMessage = null;
    });
  }

  Future<void> _stopAudioRecording() async {
    final path = await audioRecorder.stop();
    setState(() {
      recordingAudio = false;
      if (path != null) {
        selectedAudioPath = path;
      }
    });
  }

  Future<void> _sendPromptToSelectedModel(InstalledModel model) async {
    final prompt = chatPromptController.text.trim();
    if (prompt.isEmpty) {
      return;
    }
    chatPromptController.clear();
    setState(() {
      testBusy = true;
      testErrorMessage = null;
      controller.chatTurns.add(ChatTurn.user(prompt));
    });

    try {
      final response = await controller.chatRunner.generateResponse(
        model: model,
        prompt: prompt,
      );
      setState(() => controller.chatTurns.add(ChatTurn.assistant(response)));
    } catch (error) {
      setState(() => testErrorMessage = '$error');
    } finally {
      setState(() => testBusy = false);
    }
  }

  Future<void> _sendAudioToSelectedModel(InstalledModel model) async {
    final audioPath = selectedAudioPath;
    if (audioPath == null) {
      return;
    }
    final prompt = chatPromptController.text.trim().isEmpty
        ? 'What did you hear? Answer briefly.'
        : chatPromptController.text.trim();
    setState(() {
      testBusy = true;
      testErrorMessage = null;
      controller.chatTurns.add(
        ChatTurn.user('Audio: ${p.basename(audioPath)}\n$prompt'),
      );
    });

    try {
      final response = model.speechToTextSupported
          ? await controller.transcribeAudio(model: model, audioPath: audioPath)
          : await controller.chatRunner.generateResponse(
              model: model,
              prompt: prompt,
              audioPath: audioPath,
            );
      setState(() => controller.chatTurns.add(ChatTurn.assistant(response)));
    } catch (error) {
      setState(() => testErrorMessage = '$error');
    } finally {
      setState(() => testBusy = false);
    }
  }

  String _testModeLabel(InstalledModel model) {
    if (model.speechToTextSupported) {
      return 'audio';
    }
    if (model.audioPromptSupported && model.textPromptSupported) {
      return 'chat/audio';
    }
    if (model.audioPromptSupported) {
      return 'audio chat';
    }
    if (model.textPromptSupported) {
      return 'chat';
    }
    return 'installed';
  }

  Future<void> _runAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

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

enum _TestInputMode { text, audio, image }

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
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF9B6BFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0D1020),
        cardTheme: CardThemeData(
          color: const Color(0xFF242640),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: Color(0xFF343957)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF2E314F),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
        ),
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
  late final TextEditingController catalogSearchController;
  late final TextEditingController hfTokenController;
  late final TextEditingController githubRepoController;
  late final TextEditingController customRepoController;
  late final TextEditingController chatPromptController;
  late final ScrollController chatScrollController;
  late final AudioRecorder audioRecorder;
  InstalledModel? selectedTestModel;
  String? selectedAudioPath;
  String? selectedImagePath;
  String? generatedAudioPath;
  bool audioInputMode = false;
  bool imageInputMode = false;
  bool recordingAudio = false;
  bool testBusy = false;
  String? testErrorMessage;
  bool obscureHfToken = true;
  bool settingsControllersHydrated = false;
  int selectedPageIndex = 0;
  String catalogFilter = 'all';

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
    githubRepoController = TextEditingController(
      text: controller.githubRepoPath,
    );
    catalogSearchController = TextEditingController();
    customRepoController = TextEditingController(
      text: controller.customHfRepoId,
    );
    chatPromptController = TextEditingController();
    chatScrollController = ScrollController();
    audioRecorder = AudioRecorder();
    controller.addListener(_handleControllerUpdate);
    unawaited(controller.initialize());
  }

  @override
  void dispose() {
    controller.removeListener(_handleControllerUpdate);
    catalogSearchController.dispose();
    hfTokenController.dispose();
    githubRepoController.dispose();
    customRepoController.dispose();
    chatPromptController.dispose();
    chatScrollController.dispose();
    audioRecorder.dispose();
    super.dispose();
  }

  void _handleControllerUpdate() {
    if (!mounted) {
      return;
    }
    setState(() {});
    if (!settingsControllersHydrated && controller.initialized) {
      settingsControllersHydrated = true;
      _syncSettingsControllers();
    }
    _scrollChatToBottom();
  }

  void _syncSettingsControllers() {
    hfTokenController.text = controller.hfToken;
    githubRepoController.text = controller.githubRepoPath;
    customRepoController.text = controller.customHfRepoId;
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !chatScrollController.hasClients) {
        return;
      }
      chatScrollController.animateTo(
        chatScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            backgroundColor: const Color(0xFF11162B),
            selectedIndex: selectedPageIndex,
            onDestinationSelected: (index) {
              setState(() => selectedPageIndex = index);
            },
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.only(top: 20, bottom: 24),
              child: Icon(Icons.hub_outlined, size: 34),
            ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.inventory_2_outlined),
                selectedIcon: Icon(Icons.inventory_2),
                label: Text('Catalog'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.download_outlined),
                selectedIcon: Icon(Icons.download),
                label: Text('Downloads'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.play_circle_outline),
                selectedIcon: Icon(Icons.play_circle),
                label: Text('Test'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('Settings'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 72,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: const BoxDecoration(color: Color(0xFF101429)),
                  child: Row(
                    children: [
                      const Text(
                        'Local Models Studio',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E314F),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text('Flutter SDK demo'),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Refresh sources',
                        onPressed: controller.loadingSources
                            ? null
                            : () => _runAction(controller.refreshSources),
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: IndexedStack(
                    index: selectedPageIndex,
                    children: [
                      _buildCatalogTab(context),
                      _buildDownloadsTab(context),
                      _buildTestTab(context),
                      _buildSettingsTab(context),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCatalogTab(BuildContext context) {
    final visibleManifests = controller.registry.manifests
        .where(_catalogManifestVisible)
        .toList(growable: false);
    final visibleReleases = controller.githubReleases
        .where(_catalogReleaseVisible)
        .toList(growable: false);
    return RefreshIndicator(
      onRefresh: controller.refreshSources,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _buildCatalogHero(context),
          if (controller.sourceErrorMessage != null) ...[
            const SizedBox(height: 16),
            _buildErrorCard(
              title: 'Source refresh error',
              message: controller.sourceErrorMessage!,
            ),
          ],
          const SizedBox(height: 20),
          _buildGitHubReleaseSection(context, visibleReleases),
          const SizedBox(height: 20),
          _buildSectionHeader(
            context,
            title: 'Manifest Catalog',
            count: visibleManifests.length,
            total: controller.registry.manifests.length,
          ),
          const SizedBox(height: 12),
          if (visibleManifests.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No models match this search/filter.'),
              ),
            )
          else
            _buildResponsiveGrid(
              context,
              visibleManifests
                  .map((manifest) => _buildManifestCard(context, manifest))
                  .toList(growable: false),
              minCardWidth: 420,
            ),
          if (controller.customHfRepoId.trim().isNotEmpty) ...[
            const SizedBox(height: 20),
            _buildSectionHeader(context, title: 'Custom Hugging Face Repo'),
            const SizedBox(height: 12),
            _buildCustomRepoCard(context),
          ],
        ],
      ),
    );
  }

  Widget _buildCatalogHero(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _buildRuntimeCard(context)),
                const SizedBox(width: 16),
                Expanded(child: _buildSourceControlCard(context)),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: catalogSearchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                labelText: 'Search models',
                hintText: 'gemma, qwen, tts, audio, vision, 4bit...',
                suffixIcon: catalogSearchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        onPressed: () {
                          catalogSearchController.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildCatalogFilterChip('all', 'All'),
                _buildCatalogFilterChip('chat', 'Chat'),
                _buildCatalogFilterChip('vision', 'Vision'),
                _buildCatalogFilterChip('audio', 'Audio input'),
                _buildCatalogFilterChip('asr', 'ASR'),
                _buildCatalogFilterChip('tts', 'TTS'),
                _buildCatalogFilterChip('image_generation', 'Image gen'),
                _buildCatalogFilterChip('installed', 'Installed'),
                _buildCatalogFilterChip('released', 'GitHub release'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCatalogFilterChip(String value, String label) {
    return FilterChip(
      selected: catalogFilter == value,
      label: Text(label),
      onSelected: (_) => setState(() => catalogFilter = value),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context, {
    required String title,
    int? count,
    int? total,
  }) {
    final countLabel = count == null
        ? ''
        : total == null || total == count
        ? ' ($count)'
        : ' ($count / $total)';
    return Text(
      '$title$countLabel',
      style: Theme.of(context).textTheme.titleLarge,
    );
  }

  Widget _buildResponsiveGrid(
    BuildContext context,
    List<Widget> children, {
    double minCardWidth = 360,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / minCardWidth).floor().clamp(
          1,
          4,
        );
        final gap = 14.0;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: children
              .map((child) => SizedBox(width: width, child: child))
              .toList(growable: false),
        );
      },
    );
  }

  bool _catalogManifestVisible(LocalModelManifest manifest) {
    return _matchesCatalogFilter(manifest) && _matchesCatalogQuery(manifest);
  }

  bool _catalogReleaseVisible(GitHubReleaseRecord release) {
    final manifest = release.manifest;
    final query = catalogSearchController.text.trim().toLowerCase();
    final filterMatches = manifest == null
        ? catalogFilter == 'all' || catalogFilter == 'released'
        : _matchesCatalogFilter(manifest);
    if (!filterMatches) {
      return false;
    }
    if (query.isEmpty) {
      return true;
    }
    return [
      release.title,
      release.tagName,
      manifest?.displayName,
      manifest?.description,
      manifest?.source.repo,
      if (manifest != null) ...manifest.tasks.map(modelTaskToString),
    ].whereType<String>().any((value) => value.toLowerCase().contains(query));
  }

  bool _matchesCatalogQuery(LocalModelManifest manifest) {
    final query = catalogSearchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return true;
    }
    return [
      manifest.id,
      manifest.displayName,
      manifest.description,
      manifest.source.repo,
      manifest.runtimeAdapter.name,
      ...manifest.tasks.map(modelTaskToString),
      ...manifest.requirements.notes,
    ].any((value) => value.toLowerCase().contains(query));
  }

  bool _matchesCatalogFilter(LocalModelManifest manifest) {
    return switch (catalogFilter) {
      'chat' => manifest.tasks.contains(ModelTask.chat),
      'vision' => manifest.tasks.contains(ModelTask.vision),
      'audio' => manifest.tasks.contains(ModelTask.audioInput),
      'asr' => manifest.tasks.contains(ModelTask.speechToText),
      'tts' =>
        manifest.tasks.contains(ModelTask.textToSpeech) ||
            manifest.tasks.contains(ModelTask.audioOutput),
      'image_generation' => manifest.tasks.contains(ModelTask.imageGeneration),
      'installed' => controller.installedModelForManifest(manifest) != null,
      'released' => controller.releaseForManifest(manifest) != null,
      _ => true,
    };
  }

  Widget _buildDownloadsTab(BuildContext context) {
    final installedBytes = controller.installedModels.fold<int>(
      0,
      (sum, model) => sum + model.sizeBytes,
    );
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
        if (controller.installedModels.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('Total disk usage: ${formatBytes(installedBytes)}'),
        ],
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

  Widget _buildSettingsTab(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'Shared app settings for source discovery, gated downloads, and future runtime configuration.',
        ),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Sources', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                TextField(
                  controller: githubRepoController,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.code),
                    labelText: 'GitHub releases repository',
                    hintText: 'IstiN/flutter_local_models',
                    helperText:
                        'Owner/repo where Studio looks for model bundle releases.',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: hfTokenController,
                  obscureText: obscureHfToken,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.key),
                    labelText: 'Hugging Face token',
                    hintText: 'hf_...',
                    helperText:
                        'Stored locally in app settings. Leave empty for public repos.',
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(() => obscureHfToken = !obscureHfToken);
                      },
                      icon: Icon(
                        obscureHfToken
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: customRepoController,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.travel_explore),
                    labelText: 'Default custom Hugging Face repo',
                    hintText: 'mlx-community/Qwen3-8B-4bit',
                  ),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _runAction(() async {
                        await controller.updateSettings(
                          hfToken: hfTokenController.text,
                          githubRepoPath: githubRepoController.text,
                          customHfRepoId: customRepoController.text,
                        );
                        await controller.refreshSources();
                      }),
                      icon: const Icon(Icons.save),
                      label: const Text('Save & Refresh'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        _syncSettingsControllers();
                        setState(() {});
                      },
                      icon: const Icon(Icons.restore),
                      label: const Text('Reset Form'),
                    ),
                  ],
                ),
                if (controller.settingsStatusMessage.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(controller.settingsStatusMessage),
                ],
              ],
            ),
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
    final useImageInput =
        selectedModel?.manifest.tasks.contains(ModelTask.vision) == true &&
        selectedModel?.manifest.runtimeAdapter == RuntimeAdapter.mlxVlm &&
        imageInputMode;
    final useSpeechOutput = selectedModel?.textToSpeechSupported == true;
    final canSendText =
        selectedModel?.textPromptSupported == true &&
        !useAudioInput &&
        !useImageInput &&
        chatPromptController.text.trim().isNotEmpty &&
        !testBusy;
    final canSendAudio =
        useAudioInput &&
        selectedAudioPath != null &&
        !recordingAudio &&
        !testBusy &&
        (selectedModel?.speechToTextSupported == true ||
            chatPromptController.text.trim().isNotEmpty);
    final canSendImage =
        useImageInput &&
        selectedImagePath != null &&
        chatPromptController.text.trim().isNotEmpty &&
        !testBusy;
    final canSendSpeech =
        useSpeechOutput &&
        chatPromptController.text.trim().isNotEmpty &&
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
                          selectedImagePath = null;
                          generatedAudioPath = null;
                          audioInputMode =
                              value?.speechToTextSupported == true &&
                              value?.textPromptSupported != true;
                          imageInputMode = false;
                          testErrorMessage = null;
                        });
                        controller.clearChat();
                      },
                    ),
                  if (selectedModel?.manifest.runtimeAdapter ==
                          RuntimeAdapter.mlxVlm &&
                      selectedModel?.textPromptSupported == true) ...[
                    const SizedBox(height: 12),
                    SegmentedButton<_TestInputMode>(
                      segments: [
                        const ButtonSegment<_TestInputMode>(
                          value: _TestInputMode.text,
                          icon: Icon(Icons.chat_bubble_outline),
                          label: Text('Text'),
                        ),
                        if (selectedModel?.audioPromptSupported == true)
                          const ButtonSegment<_TestInputMode>(
                            value: _TestInputMode.audio,
                            icon: Icon(Icons.graphic_eq),
                            label: Text('Audio'),
                          ),
                        if (selectedModel?.manifest.tasks.contains(
                              ModelTask.vision,
                            ) ==
                            true)
                          const ButtonSegment<_TestInputMode>(
                            value: _TestInputMode.image,
                            icon: Icon(Icons.image_outlined),
                            label: Text('Image'),
                          ),
                      ],
                      selected: <_TestInputMode>{
                        imageInputMode
                            ? _TestInputMode.image
                            : audioInputMode
                            ? _TestInputMode.audio
                            : _TestInputMode.text,
                      },
                      onSelectionChanged: testBusy || recordingAudio
                          ? null
                          : (selection) {
                              final mode = selection.first;
                              setState(() {
                                audioInputMode = mode == _TestInputMode.audio;
                                imageInputMode = mode == _TestInputMode.image;
                                selectedAudioPath = null;
                                selectedImagePath = null;
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
                ? Card(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.auto_awesome,
                              size: 42,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Choose a model, send text, audio, or image, and watch the local response stream here.',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    controller: chatScrollController,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: controller.chatTurns.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final turn = controller.chatTurns[index];
                      final alignment = turn.isUser
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start;
                      final color = turn.isUser
                          ? const Color(0xFF59447D)
                          : const Color(0xFF30334F);
                      return Column(
                        crossAxisAlignment: alignment,
                        children: [
                          Text(
                            turn.isUser ? 'You' : 'Model',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            constraints: const BoxConstraints(maxWidth: 980),
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            padding: const EdgeInsets.all(18),
                            child: SelectableText(turn.message),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          const SizedBox(height: 16),
          if (useSpeechOutput && selectedModel != null)
            Column(
              children: [
                TextField(
                  controller: chatPromptController,
                  minLines: 2,
                  maxLines: 4,
                  onChanged: (_) => setState(() {}),
                  enabled: !testBusy,
                  decoration: const InputDecoration(
                    labelText: 'Speech text',
                    border: OutlineInputBorder(),
                    hintText: 'Type text to synthesize locally...',
                  ),
                ),
                if (generatedAudioPath != null) ...[
                  const SizedBox(height: 12),
                  Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      leading: const Icon(Icons.graphic_eq),
                      title: Text(p.basename(generatedAudioPath!)),
                      subtitle: SelectableText(generatedAudioPath!),
                      trailing: IconButton(
                        tooltip: 'Play generated audio',
                        onPressed: () =>
                            Process.run('open', [generatedAudioPath!]),
                        icon: const Icon(Icons.play_arrow),
                      ),
                    ),
                  ),
                ],
              ],
            )
          else if (useAudioInput && selectedModel != null)
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
                      hintText:
                          'Ask what the model should do with the audio...',
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _buildAudioInputBar(selectedModel),
              ],
            )
          else if (useImageInput && selectedModel != null)
            Column(
              children: [
                TextField(
                  controller: chatPromptController,
                  minLines: 2,
                  maxLines: 4,
                  onChanged: (_) => setState(() {}),
                  enabled: !testBusy,
                  decoration: const InputDecoration(
                    labelText: 'Image prompt',
                    border: OutlineInputBorder(),
                    hintText: 'Ask what the model should do with the image...',
                  ),
                ),
                const SizedBox(height: 12),
                _buildImageInputBar(),
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
              else if (useSpeechOutput && selectedModel != null)
                FilledButton.icon(
                  onPressed: canSendSpeech
                      ? () => _sendTtsToSelectedModel(selectedModel)
                      : null,
                  icon: testBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.record_voice_over),
                  label: Text(testBusy ? 'Running...' : 'Generate Speech'),
                )
              else if (useImageInput && selectedModel != null)
                FilledButton.icon(
                  onPressed: canSendImage
                      ? () => _sendImageToSelectedModel(selectedModel)
                      : null,
                  icon: testBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  label: Text(testBusy ? 'Running...' : 'Send Image'),
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

  Widget _buildImageInputBar() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.image_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                selectedImagePath == null
                    ? 'No image selected'
                    : p.basename(selectedImagePath!),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: testBusy ? null : _chooseImageFile,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseImageFile() async {
    const imageTypeGroup = XTypeGroup(
      label: 'images',
      extensions: <String>['png', 'jpg', 'jpeg', 'webp', 'heic'],
    );
    final file = await openFile(
      acceptedTypeGroups: <XTypeGroup>[imageTypeGroup],
    );
    if (file == null) {
      return;
    }
    setState(() => selectedImagePath = file.path);
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
              'Browse configured Hugging Face repos, inspect GitHub releases, and test downloads with pause, resume, cancel, and delete.',
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: controller.loadingSources
                      ? null
                      : () => _runAction(controller.refreshSources),
                  icon: const Icon(Icons.refresh),
                  label: Text(
                    controller.loadingSources ? 'Refreshing...' : 'Refresh All',
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => setState(() => selectedPageIndex = 3),
                  icon: const Icon(Icons.settings),
                  label: const Text('Source Settings'),
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

  Widget _buildGitHubReleaseSection(
    BuildContext context,
    List<GitHubReleaseRecord> releases,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          context,
          title: 'GitHub Releases',
          count: releases.length,
          total: controller.githubReleases.length,
        ),
        const SizedBox(height: 12),
        if (releases.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No GitHub releases are published yet for the current catalog.',
              ),
            ),
          )
        else
          _buildResponsiveGrid(
            context,
            releases
                .map((release) => _buildReleaseCard(context, release))
                .toList(growable: false),
          ),
      ],
    );
  }

  Widget _buildReleaseCard(BuildContext context, GitHubReleaseRecord release) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(release.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Tag: ${release.tagName}'),
            Text('Assets: ${release.assets.length}'),
            Text(
              'Total asset size: ${formatBytes(release.assets.fold<int>(0, (sum, asset) => sum + asset.sizeBytes))}',
            ),
            if (release.manifest != null)
              Text('Matches manifest: ${release.manifest!.displayName}'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: release.hasBundleAssets
                      ? () => _runAction(
                          () => controller.startGitHubReleaseDownload(release),
                        )
                      : null,
                  icon: const Icon(Icons.download),
                  label: const Text('Download Release'),
                ),
                if (release.manifest != null &&
                    controller.installedModelForManifest(release.manifest!) !=
                        null)
                  OutlinedButton.icon(
                    onPressed: () {
                      final installed = controller.installedModelForManifest(
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
                    onPressed: _isModelOpenableInTest(installed)
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
            Text('Size: ${formatBytes(model.sizeBytes)}'),
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

  bool _isModelOpenableInTest(InstalledModel model) {
    return model.textPromptSupported ||
        model.audioPromptSupported ||
        model.speechToTextSupported ||
        model.textToSpeechSupported ||
        model.manifest.tasks.contains(ModelTask.vision);
  }

  void _openModelInTest(InstalledModel model, BuildContext context) {
    setState(() {
      selectedTestModel = model;
      selectedAudioPath = null;
      selectedImagePath = null;
      imageInputMode = false;
      audioInputMode =
          model.speechToTextSupported && model.textPromptSupported != true;
      testErrorMessage = null;
      selectedPageIndex = 2;
    });
    controller.clearChat();
  }

  Future<void> _chooseAudioFile() async {
    const audioTypeGroup = XTypeGroup(
      label: 'audio',
      extensions: <String>['wav', 'mp3', 'm4a', 'aac', 'flac', 'ogg'],
    );
    final file = await openFile(
      acceptedTypeGroups: <XTypeGroup>[audioTypeGroup],
    );
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
    final messages = _messagesForCurrentChat(LocalChatMessage.user(prompt));
    chatPromptController.clear();
    setState(() {
      testBusy = true;
      testErrorMessage = null;
      controller.chatTurns.add(ChatTurn.user(prompt));
      controller.chatTurns.add(const ChatTurn.assistant(''));
    });
    _scrollChatToBottom();

    try {
      await controller.chatRunner.chatStream(
        model: model,
        messages: messages,
        params: LocalChatParams(modelId: model.manifest.id),
        onText: _replaceStreamingAssistant,
      );
    } catch (error) {
      setState(() => testErrorMessage = '$error');
    } finally {
      setState(() => testBusy = false);
      _scrollChatToBottom();
    }
  }

  Future<void> _sendAudioToSelectedModel(InstalledModel model) async {
    final audioPath = selectedAudioPath;
    if (audioPath == null) {
      return;
    }
    final prompt = chatPromptController.text.trim();
    if (!model.speechToTextSupported && prompt.isEmpty) {
      return;
    }
    final userMessage = prompt.isEmpty
        ? 'Audio: ${p.basename(audioPath)}'
        : 'Audio: ${p.basename(audioPath)}\n$prompt';
    final messages = _messagesForCurrentChat(
      LocalChatMessage.user(
        prompt,
        attachments: [
          LocalMessageAttachment.file(
            type: LocalAttachmentType.audio,
            path: audioPath,
          ),
        ],
      ),
    );
    setState(() {
      testBusy = true;
      testErrorMessage = null;
      controller.chatTurns.add(ChatTurn.user(userMessage));
    });
    _scrollChatToBottom();

    try {
      if (model.speechToTextSupported) {
        final response = await controller.transcribeAudio(
          model: model,
          audioPath: audioPath,
        );
        setState(() => controller.chatTurns.add(ChatTurn.assistant(response)));
      } else {
        setState(() => controller.chatTurns.add(const ChatTurn.assistant('')));
        await controller.chatRunner.chatStream(
          model: model,
          messages: messages,
          params: LocalChatParams(modelId: model.manifest.id),
          onText: _replaceStreamingAssistant,
        );
      }
    } catch (error) {
      setState(() => testErrorMessage = '$error');
    } finally {
      setState(() => testBusy = false);
      _scrollChatToBottom();
    }
  }

  Future<void> _sendImageToSelectedModel(InstalledModel model) async {
    final imagePath = selectedImagePath;
    if (imagePath == null) {
      return;
    }
    final prompt = chatPromptController.text.trim();
    if (prompt.isEmpty) {
      return;
    }
    final messages = _messagesForCurrentChat(
      LocalChatMessage.user(
        prompt,
        attachments: [
          LocalMessageAttachment.file(
            type: LocalAttachmentType.image,
            path: imagePath,
          ),
        ],
      ),
    );
    chatPromptController.clear();
    setState(() {
      testBusy = true;
      testErrorMessage = null;
      controller.chatTurns.add(
        ChatTurn.user('Image: ${p.basename(imagePath)}\n$prompt'),
      );
      controller.chatTurns.add(const ChatTurn.assistant(''));
    });
    _scrollChatToBottom();

    try {
      await controller.chatRunner.chatStream(
        model: model,
        messages: messages,
        params: LocalChatParams(modelId: model.manifest.id),
        onText: _replaceStreamingAssistant,
      );
    } catch (error) {
      setState(() => testErrorMessage = '$error');
    } finally {
      setState(() => testBusy = false);
      _scrollChatToBottom();
    }
  }

  Future<void> _sendTtsToSelectedModel(InstalledModel model) async {
    final text = chatPromptController.text.trim();
    if (text.isEmpty) {
      return;
    }
    setState(() {
      testBusy = true;
      testErrorMessage = null;
      generatedAudioPath = null;
      controller.chatTurns.add(ChatTurn.user(text));
      controller.chatTurns.add(
        const ChatTurn.assistant('Generating local speech...'),
      );
    });
    _scrollChatToBottom();

    try {
      final file = await controller.synthesizeSpeech(model: model, text: text);
      setState(() => generatedAudioPath = file.path);
      _replaceStreamingAssistant('Generated audio: ${file.path}');
    } catch (error) {
      setState(() => testErrorMessage = '$error');
    } finally {
      setState(() => testBusy = false);
      _scrollChatToBottom();
    }
  }

  void _replaceStreamingAssistant(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      final lastIndex = controller.chatTurns.lastIndexWhere(
        (turn) => !turn.isUser,
      );
      if (lastIndex == -1) {
        controller.chatTurns.add(ChatTurn.assistant(message));
      } else {
        controller.chatTurns[lastIndex] = ChatTurn.assistant(message);
      }
    });
    _scrollChatToBottom();
  }

  List<LocalChatMessage> _messagesForCurrentChat(LocalChatMessage nextMessage) {
    final messages = <LocalChatMessage>[];
    for (final turn in controller.chatTurns) {
      if (turn.message.trim().isEmpty) {
        continue;
      }
      messages.add(
        turn.isUser
            ? LocalChatMessage.user(turn.message)
            : LocalChatMessage.assistant(turn.message),
      );
    }
    messages.add(nextMessage);
    return messages;
  }

  String _testModeLabel(InstalledModel model) {
    if (model.textToSpeechSupported) {
      return 'tts';
    }
    if (model.speechToTextSupported) {
      return 'audio';
    }
    if (model.manifest.runtimeAdapter == RuntimeAdapter.mlxVlm &&
        model.textPromptSupported) {
      final modes = <String>['chat'];
      if (model.audioPromptSupported) {
        modes.add('audio');
      }
      if (model.manifest.tasks.contains(ModelTask.vision)) {
        modes.add('image');
      }
      return modes.join('/');
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

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
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

enum _TestWorkspaceMode { single, voicePipeline }

class StudioSvgIcon extends StatelessWidget {
  const StudioSvgIcon(this.name, {super.key, this.size = 24, this.opacity = 1});

  final String name;
  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: SvgPicture.asset(
        'assets/icons/$name.svg',
        width: size,
        height: size,
      ),
    );
  }
}

T? _firstWhereOrNull<T>(Iterable<T> values, bool Function(T value) test) {
  for (final value in values) {
    if (test(value)) {
      return value;
    }
  }
  return null;
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
  late final TextEditingController downloadRetryCountController;
  late final TextEditingController chatPromptController;
  late final TextEditingController ttsVoiceController;
  late final TextEditingController ttsInstructController;
  late final TextEditingController ttsLanguageController;
  late final TextEditingController ttsSpeedController;
  late final ScrollController chatScrollController;
  late final AudioRecorder audioRecorder;
  late final AudioPlayer audioPlayer;
  InstalledModel? selectedTestModel;
  InstalledModel? selectedAsrModel;
  InstalledModel? selectedVoiceChatModel;
  InstalledModel? selectedTtsModel;
  String? selectedAudioPath;
  String? selectedImagePath;
  String? ttsReferenceAudioPath;
  String? generatedAudioPath;
  String? playingAudioPath;
  bool audioInputMode = false;
  bool imageInputMode = false;
  _TestWorkspaceMode testWorkspaceMode = _TestWorkspaceMode.single;
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
    downloadRetryCountController = TextEditingController(
      text: controller.maxDownloadRetries.toString(),
    );
    chatPromptController = TextEditingController();
    ttsVoiceController = TextEditingController(text: 'Ethan');
    ttsInstructController = TextEditingController(
      text: 'A calm, natural assistant voice with stable tone.',
    );
    ttsLanguageController = TextEditingController(text: 'ru');
    ttsSpeedController = TextEditingController(text: '1.0');
    chatScrollController = ScrollController();
    audioRecorder = AudioRecorder();
    audioPlayer = AudioPlayer();
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
    downloadRetryCountController.dispose();
    chatPromptController.dispose();
    ttsVoiceController.dispose();
    ttsInstructController.dispose();
    ttsLanguageController.dispose();
    ttsSpeedController.dispose();
    chatScrollController.dispose();
    audioRecorder.dispose();
    audioPlayer.dispose();
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
    downloadRetryCountController.text = controller.maxDownloadRetries
        .toString();
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
              child: StudioSvgIcon('logo_mark', size: 36),
            ),
            destinations: const [
              NavigationRailDestination(
                icon: StudioSvgIcon('catalog', opacity: 0.6),
                selectedIcon: StudioSvgIcon('catalog'),
                label: Text('Catalog'),
              ),
              NavigationRailDestination(
                icon: StudioSvgIcon('downloads', opacity: 0.6),
                selectedIcon: StudioSvgIcon('downloads'),
                label: Text('Downloads'),
              ),
              NavigationRailDestination(
                icon: StudioSvgIcon('test', opacity: 0.6),
                selectedIcon: StudioSvgIcon('test'),
                label: Text('Test'),
              ),
              NavigationRailDestination(
                icon: StudioSvgIcon('settings', opacity: 0.6),
                selectedIcon: StudioSvgIcon('settings'),
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
                        icon: const StudioSvgIcon('refresh'),
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
                prefixIcon: StudioSvgIcon('search', size: 22),
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
                    prefixIcon: StudioSvgIcon('github', size: 22),
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
                    prefixIcon: StudioSvgIcon('key', size: 22),
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
                    prefixIcon: StudioSvgIcon('search', size: 22),
                    labelText: 'Default custom Hugging Face repo',
                    hintText: 'mlx-community/Qwen3-8B-4bit',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: downloadRetryCountController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    prefixIcon: StudioSvgIcon('refresh', size: 22),
                    labelText: 'Download auto retries',
                    helperText:
                        'Retries transient curl/network/file-size failures before stopping.',
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
                          maxDownloadRetries:
                              int.tryParse(
                                downloadRetryCountController.text.trim(),
                              ) ??
                              controller.maxDownloadRetries,
                        );
                        await controller.refreshSources();
                      }),
                      icon: const StudioSvgIcon('downloads', size: 20),
                      label: const Text('Save & Refresh'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        _syncSettingsControllers();
                        setState(() {});
                      },
                      icon: const StudioSvgIcon('refresh', size: 20),
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
    final useImageGeneration = selectedModel?.imageGenerationSupported == true;
    final useSpeechOutput = selectedModel?.textToSpeechSupported == true;
    final canSendText =
        selectedModel?.textPromptSupported == true &&
        !useAudioInput &&
        !useImageInput &&
        !useImageGeneration &&
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
    final canGenerateImage =
        useImageGeneration &&
        chatPromptController.text.trim().isNotEmpty &&
        !testBusy;
    final canSendSpeech =
        useSpeechOutput &&
        chatPromptController.text.trim().isNotEmpty &&
        !testBusy;
    final asrModels = installedModels
        .where((model) => model.speechToTextSupported)
        .toList(growable: false);
    final voiceChatModels = installedModels
        .where((model) => model.textPromptSupported)
        .toList(growable: false);
    final ttsModels = installedModels
        .where((model) => model.textToSpeechSupported)
        .toList(growable: false);

    if (testWorkspaceMode == _TestWorkspaceMode.voicePipeline) {
      return _buildVoicePipelineTab(
        context,
        asrModels: asrModels,
        chatModels: voiceChatModels,
        ttsModels: ttsModels,
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTestModeSwitch(),
          const SizedBox(height: 12),
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
                          if (value?.textToSpeechSupported == true) {
                            _applyTtsDefaultsForModel(value);
                          }
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
                          icon: StudioSvgIcon('chat', size: 20),
                          label: Text('Text'),
                        ),
                        if (selectedModel?.audioPromptSupported == true)
                          const ButtonSegment<_TestInputMode>(
                            value: _TestInputMode.audio,
                            icon: StudioSvgIcon('audio', size: 20),
                            label: Text('Audio'),
                          ),
                        if (selectedModel?.manifest.tasks.contains(
                              ModelTask.vision,
                            ) ==
                            true)
                          const ButtonSegment<_TestInputMode>(
                            value: _TestInputMode.image,
                            icon: StudioSvgIcon('image', size: 20),
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
          Expanded(child: _buildConversationPane(context)),
          const SizedBox(height: 16),
          if (useSpeechOutput && selectedModel != null)
            Column(
              children: [
                _buildTtsVoiceControls(selectedModel),
                const SizedBox(height: 12),
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
          else if (useImageGeneration && selectedModel != null)
            TextField(
              controller: chatPromptController,
              minLines: 3,
              maxLines: 6,
              onChanged: (_) => setState(() {}),
              enabled: !testBusy,
              decoration: const InputDecoration(
                labelText: 'Image prompt',
                border: OutlineInputBorder(),
                hintText: 'Describe the image you want to generate...',
              ),
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
                    : selectedModel.imageGenerationSupported
                    ? 'Describe the image you want to generate...'
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
                      : const StudioSvgIcon('send', size: 22),
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
                      : const StudioSvgIcon('mic', size: 22),
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
                      : const StudioSvgIcon('send', size: 22),
                  label: Text(testBusy ? 'Running...' : 'Send Image'),
                )
              else if (useImageGeneration && selectedModel != null)
                FilledButton.icon(
                  onPressed: canGenerateImage
                      ? () => _generateImageWithSelectedModel(selectedModel)
                      : null,
                  icon: testBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const StudioSvgIcon('image', size: 22),
                  label: Text(testBusy ? 'Generating...' : 'Generate Image'),
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
                      : const StudioSvgIcon('send', size: 22),
                  label: Text(testBusy ? 'Running...' : 'Send Message'),
                ),
              OutlinedButton.icon(
                onPressed: testBusy || controller.chatTurns.isEmpty
                    ? null
                    : controller.clearChat,
                icon: const StudioSvgIcon('trash', size: 20),
                label: const Text('Clear'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChatTurnBody(ChatTurn turn) {
    final imagePath = turn.imagePath;
    final audioPath = turn.audioPath;
    if (imagePath == null && audioPath == null) {
      return SelectableText(turn.message);
    }
    if (imagePath != null) {
      final imageFile = File(imagePath);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (turn.message.trim().isNotEmpty) ...[
            SelectableText(turn.message),
            const SizedBox(height: 12),
          ],
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
              color: const Color(0xFF1C2038),
              child: imageFile.existsSync()
                  ? Image.file(imageFile, fit: BoxFit.contain)
                  : Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Generated image not found: $imagePath'),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            p.basename(imagePath),
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ],
      );
    }
    if (audioPath == null) {
      return SelectableText(turn.message);
    }
    final isPlaying = playingAudioPath == audioPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (turn.message.trim().isNotEmpty) ...[
          SelectableText(turn.message),
          const SizedBox(height: 12),
        ],
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1C2038),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFF464B70)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton.filledTonal(
                tooltip: isPlaying ? 'Stop audio' : 'Play audio',
                onPressed: () => _toggleAudioPlayback(audioPath),
                icon: StudioSvgIcon(isPlaying ? 'stop' : 'play', size: 20),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.basename(audioPath)),
                  Text(
                    [
                      'Generated speech',
                      if (turn.duration != null)
                        _formatDuration(turn.duration!),
                    ].join(' • '),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTestModeSwitch() {
    return SegmentedButton<_TestWorkspaceMode>(
      segments: const [
        ButtonSegment<_TestWorkspaceMode>(
          value: _TestWorkspaceMode.single,
          icon: StudioSvgIcon('test', size: 20),
          label: Text('Single model'),
        ),
        ButtonSegment<_TestWorkspaceMode>(
          value: _TestWorkspaceMode.voicePipeline,
          icon: StudioSvgIcon('mic', size: 20),
          label: Text('Voice → Voice'),
        ),
      ],
      selected: <_TestWorkspaceMode>{testWorkspaceMode},
      onSelectionChanged: testBusy || recordingAudio
          ? null
          : (selection) {
              setState(() {
                testWorkspaceMode = selection.first;
                testErrorMessage = null;
              });
            },
    );
  }

  Widget _buildVoicePipelineTab(
    BuildContext context, {
    required List<InstalledModel> asrModels,
    required List<InstalledModel> chatModels,
    required List<InstalledModel> ttsModels,
  }) {
    final asrModel = asrModels.contains(selectedAsrModel)
        ? selectedAsrModel
        : asrModels.isEmpty
        ? null
        : asrModels.first;
    final chatModel = chatModels.contains(selectedVoiceChatModel)
        ? selectedVoiceChatModel
        : chatModels.isEmpty
        ? null
        : chatModels.first;
    final ttsModel = ttsModels.contains(selectedTtsModel)
        ? selectedTtsModel
        : ttsModels.isEmpty
        ? null
        : ttsModels.first;
    final canRun =
        asrModel != null &&
        chatModel != null &&
        ttsModel != null &&
        selectedAudioPath != null &&
        !recordingAudio &&
        !testBusy;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTestModeSwitch(),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Voice pipeline',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Record once, then run ASR → LLM response → TTS playback locally.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _buildModelDropdown(
                          label: 'ASR model',
                          icon: const StudioSvgIcon('audio', size: 22),
                          models: asrModels,
                          value: asrModel,
                          emptyText: 'Install a speech-to-text model',
                          onChanged: (value) =>
                              setState(() => selectedAsrModel = value),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildModelDropdown(
                          label: 'Response model',
                          icon: const StudioSvgIcon('chat', size: 22),
                          models: chatModels,
                          value: chatModel,
                          emptyText: 'Install a chat model',
                          onChanged: (value) =>
                              setState(() => selectedVoiceChatModel = value),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildModelDropdown(
                          label: 'TTS model',
                          icon: const StudioSvgIcon('mic', size: 22),
                          models: ttsModels,
                          value: ttsModel,
                          emptyText: 'Install a text-to-speech model',
                          onChanged: (value) {
                            setState(() {
                              selectedTtsModel = value;
                              _applyTtsDefaultsForModel(value);
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _buildTtsVoiceControls(ttsModel),
                  const SizedBox(height: 14),
                  TextField(
                    controller: chatPromptController,
                    minLines: 2,
                    maxLines: 3,
                    enabled: !testBusy,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Question / instruction',
                      hintText:
                          'Optional: e.g. answer briefly, translate, explain...',
                    ),
                  ),
                  const SizedBox(height: 14),
                  _buildAudioInputBar(asrModel),
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
          Expanded(child: _buildConversationPane(context)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: canRun
                    ? () => _runVoicePipeline(
                        asrModel: asrModel,
                        chatModel: chatModel,
                        ttsModel: ttsModel,
                      )
                    : null,
                icon: testBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const StudioSvgIcon('send', size: 22),
                label: Text(testBusy ? 'Running pipeline...' : 'Run Voice UX'),
              ),
              OutlinedButton.icon(
                onPressed: testBusy || controller.chatTurns.isEmpty
                    ? null
                    : () {
                        controller.clearChat();
                        setState(() {
                          generatedAudioPath = null;
                        });
                      },
                icon: const StudioSvgIcon('trash', size: 20),
                label: const Text('Clear'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConversationPane(BuildContext context) {
    if (controller.chatTurns.isEmpty) {
      return Card(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const StudioSvgIcon('sparkle', size: 48),
                const SizedBox(height: 12),
                Text(
                  testWorkspaceMode == _TestWorkspaceMode.voicePipeline
                      ? 'Record voice and the full local assistant loop will appear here.'
                      : 'Choose a model, send text, audio, or image, and watch the local response stream here.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return ListView.separated(
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
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(height: 4),
            Container(
              constraints: const BoxConstraints(maxWidth: 980),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(22),
              ),
              padding: const EdgeInsets.all(18),
              child: _buildChatTurnBody(turn),
            ),
          ],
        );
      },
    );
  }

  Widget _buildModelDropdown({
    required String label,
    required Widget icon,
    required List<InstalledModel> models,
    required InstalledModel? value,
    required String emptyText,
    required ValueChanged<InstalledModel?> onChanged,
  }) {
    return DropdownButtonFormField<InstalledModel>(
      initialValue: value,
      decoration: InputDecoration(
        prefixIcon: Padding(padding: const EdgeInsets.all(12), child: icon),
        labelText: label,
      ),
      items: models
          .map(
            (model) => DropdownMenuItem<InstalledModel>(
              value: model,
              child: Text(
                model.manifest.displayName,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(growable: false),
      hint: Text(emptyText),
      onChanged: testBusy ? null : onChanged,
    );
  }

  Widget _buildTtsVoiceControls(InstalledModel? model) {
    final voiceNames =
        model?.manifest.runtimeConfig.voices
            .map((voice) => voice.id)
            .where((id) => id.trim().isNotEmpty && id != 'default')
            .toList(growable: false) ??
        const <String>[];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'TTS voice lock',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: ttsVoiceController,
                    enabled: !testBusy,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Voice / speaker',
                      hintText: voiceNames.isEmpty
                          ? 'Ethan, Chelsie, Vivian...'
                          : voiceNames.join(', '),
                      prefixIcon: const Padding(
                        padding: EdgeInsets.all(12),
                        child: StudioSvgIcon('mic', size: 20),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: ttsLanguageController,
                    enabled: !testBusy,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Language',
                      hintText: 'ru',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: ttsSpeedController,
                    enabled: !testBusy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Speed',
                      hintText: '1.0',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ttsInstructController,
              enabled: !testBusy,
              minLines: 2,
              maxLines: 3,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Voice design / instruction',
                hintText:
                    'A calm middle-aged male voice speaking Russian clearly...',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const StudioSvgIcon('audio', size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    ttsReferenceAudioPath == null
                        ? 'No reference voice audio selected'
                        : p.basename(ttsReferenceAudioPath!),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: testBusy ? null : _chooseTtsReferenceAudioFile,
                  icon: const StudioSvgIcon('folder', size: 20),
                  label: const Text('Ref Audio'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: testBusy || ttsReferenceAudioPath == null
                      ? null
                      : () => setState(() => ttsReferenceAudioPath = null),
                  icon: const StudioSvgIcon('trash', size: 18),
                  label: const Text('Clear'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioInputBar(InstalledModel? _) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            StudioSvgIcon(recordingAudio ? 'mic' : 'audio', size: 24),
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
              icon: StudioSvgIcon(recordingAudio ? 'stop' : 'mic', size: 20),
              label: Text(recordingAudio ? 'Stop' : 'Record'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: recordingAudio || testBusy ? null : _chooseAudioFile,
              icon: const StudioSvgIcon('folder', size: 20),
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
            const StudioSvgIcon('image', size: 20),
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
              icon: const StudioSvgIcon('folder', size: 20),
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
                  icon: const StudioSvgIcon('refresh', size: 20),
                  label: Text(
                    controller.loadingSources ? 'Refreshing...' : 'Refresh All',
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => setState(() => selectedPageIndex = 3),
                  icon: const StudioSvgIcon('settings', size: 20),
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
                  icon: const StudioSvgIcon('search', size: 22),
                  label: const Text('Load HF Repo'),
                ),
                if (controller.customHfRepoDetails != null)
                  FilledButton.icon(
                    onPressed: () =>
                        _runAction(controller.startCustomHuggingFaceDownload),
                    icon: const StudioSvgIcon('downloads', size: 20),
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
                  icon: const StudioSvgIcon('downloads', size: 20),
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
                    icon: StudioSvgIcon('chat', size: 20),
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
            if (!manifest.modelCard.isEmpty) ...[
              const SizedBox(height: 8),
              _buildModelCardDetails(context, manifest.modelCard),
            ],
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
            if (!manifest.runtimeConfig.isEmpty) ...[
              const SizedBox(height: 8),
              Text(_runtimeConfigSummary(manifest.runtimeConfig)),
            ],
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
                  icon: const StudioSvgIcon('downloads', size: 20),
                  label: const Text('Download from HF'),
                ),
                OutlinedButton.icon(
                  onPressed: release == null
                      ? null
                      : () => _runAction(
                          () => controller.startGitHubReleaseDownload(release),
                        ),
                  icon: const StudioSvgIcon('catalog', size: 20),
                  label: const Text('Download Release'),
                ),
                if (installed != null)
                  OutlinedButton.icon(
                    onPressed: _isModelOpenableInTest(installed)
                        ? () => _openModelInChat(installed, context)
                        : null,
                    icon: StudioSvgIcon('chat', size: 20),
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
                  icon: const StudioSvgIcon('downloads', size: 20),
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
    final speedBytesPerSecond = task.effectiveDownloadSpeedBytesPerSecond;
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
            if (task.retryAttempt > 0)
              Text(
                'Retry: ${task.retryAttempt} / ${controller.maxDownloadRetries}',
              ),
            if (task.totalBytes > 0)
              Text(
                [
                  '${formatBytes(task.downloadedBytes)} / ${formatBytes(task.totalBytes)}',
                  if (task.status == DownloadTaskStatus.running)
                    speedBytesPerSecond > 0
                        ? '${formatBytes(speedBytesPerSecond)}/s'
                        : 'speed: measuring…',
                ].join(' • '),
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
                  icon: const StudioSvgIcon('pause', size: 20),
                  label: const Text('Pause'),
                ),
                OutlinedButton.icon(
                  onPressed: task.canResume
                      ? () => controller.resumeDownload(task)
                      : null,
                  icon: const StudioSvgIcon('play', size: 20),
                  label: const Text('Resume'),
                ),
                OutlinedButton.icon(
                  onPressed: task.canCancel
                      ? () => controller.cancelDownload(task)
                      : null,
                  icon: const StudioSvgIcon('stop', size: 20),
                  label: const Text('Cancel'),
                ),
                TextButton.icon(
                  onPressed: task.canClear
                      ? () => controller.clearDownload(task)
                      : null,
                  icon: const StudioSvgIcon('trash', size: 20),
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
                  icon: const StudioSvgIcon('play', size: 20),
                  label: const Text('Open in Test'),
                ),
                OutlinedButton.icon(
                  onPressed: () => controller.deleteInstalledModel(model),
                  icon: const StudioSvgIcon('trash', size: 20),
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
        model.imageGenerationSupported ||
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
      if (model.textToSpeechSupported) {
        _applyTtsDefaultsForModel(model);
      }
    });
    controller.clearChat();
  }

  void _applyTtsDefaultsForModel(InstalledModel? model) {
    if (model == null) {
      return;
    }
    final defaults = model.manifest.runtimeConfig.defaultParameters;
    final voice = defaults['voice'] as String?;
    final voicePrompt =
        defaults['instruct'] as String? ?? defaults['voice_prompt'] as String?;
    final language =
        defaults['lang_code'] as String? ?? defaults['language'] as String?;
    final speed = defaults['speed'];
    if (voice != null && voice.trim().isNotEmpty) {
      ttsVoiceController.text = voice.trim();
    } else if (model.manifest.id.contains('qwen3-tts')) {
      ttsVoiceController.text = 'Ethan';
    }
    if (voicePrompt != null && voicePrompt.trim().isNotEmpty) {
      ttsInstructController.text = voicePrompt.trim();
    }
    if (language != null && language.trim().isNotEmpty) {
      ttsLanguageController.text = language.trim();
    }
    if (speed != null) {
      ttsSpeedController.text = '$speed';
    }
  }

  Future<void> _chooseAudioFile() async {
    final file = await _openAudioFile();
    if (file == null) {
      return;
    }
    setState(() => selectedAudioPath = file.path);
  }

  Future<void> _chooseTtsReferenceAudioFile() async {
    final file = await _openAudioFile();
    if (file == null) {
      return;
    }
    setState(() => ttsReferenceAudioPath = file.path);
  }

  Future<XFile?> _openAudioFile() {
    const audioTypeGroup = XTypeGroup(
      label: 'audio',
      extensions: <String>['wav', 'mp3', 'm4a', 'aac', 'flac', 'ogg'],
    );
    return openFile(acceptedTypeGroups: <XTypeGroup>[audioTypeGroup]);
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
    if (path != null && testWorkspaceMode == _TestWorkspaceMode.voicePipeline) {
      _runVoicePipelineWithCurrentSelection();
    }
  }

  void _runVoicePipelineWithCurrentSelection() {
    if (testBusy || recordingAudio || selectedAudioPath == null) {
      return;
    }
    final installedModels = controller.installedModels;
    final asrModel = _firstWhereOrNull(
      installedModels,
      (model) =>
          model.speechToTextSupported &&
          (selectedAsrModel == null ||
              model.directory.path == selectedAsrModel!.directory.path),
    );
    final chatModel = _firstWhereOrNull(
      installedModels,
      (model) =>
          model.textPromptSupported &&
          (selectedVoiceChatModel == null ||
              model.directory.path == selectedVoiceChatModel!.directory.path),
    );
    final ttsModel = _firstWhereOrNull(
      installedModels,
      (model) =>
          model.textToSpeechSupported &&
          (selectedTtsModel == null ||
              model.directory.path == selectedTtsModel!.directory.path),
    );
    final resolvedAsr =
        asrModel ??
        _firstWhereOrNull(
          installedModels,
          (model) => model.speechToTextSupported,
        );
    final resolvedChat =
        chatModel ??
        _firstWhereOrNull(
          installedModels,
          (model) => model.textPromptSupported,
        );
    final resolvedTts =
        ttsModel ??
        _firstWhereOrNull(
          installedModels,
          (model) => model.textToSpeechSupported,
        );
    if (resolvedAsr == null || resolvedChat == null || resolvedTts == null) {
      setState(() {
        testErrorMessage =
            'Install/select ASR, response, and TTS models before recording.';
      });
      return;
    }
    setState(() {
      selectedAsrModel = resolvedAsr;
      selectedVoiceChatModel = resolvedChat;
      selectedTtsModel = resolvedTts;
    });
    unawaited(
      _runVoicePipeline(
        asrModel: resolvedAsr,
        chatModel: resolvedChat,
        ttsModel: resolvedTts,
      ),
    );
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

  Future<void> _generateImageWithSelectedModel(InstalledModel model) async {
    final prompt = chatPromptController.text.trim();
    if (prompt.isEmpty) {
      return;
    }
    chatPromptController.clear();
    setState(() {
      testBusy = true;
      testErrorMessage = null;
      controller.chatTurns.add(ChatTurn.user(prompt));
      controller.chatTurns.add(const ChatTurn.assistant('Generating image...'));
    });
    _scrollChatToBottom();

    try {
      final imageFile = await controller.generateImage(
        model: model,
        prompt: prompt,
      );
      setState(() {
        final lastIndex = controller.chatTurns.lastIndexWhere(
          (turn) => !turn.isUser,
        );
        final generatedTurn = ChatTurn.assistant(
          'Generated image',
          imagePath: imageFile.path,
        );
        if (lastIndex == -1) {
          controller.chatTurns.add(generatedTurn);
        } else {
          controller.chatTurns[lastIndex] = generatedTurn;
        }
      });
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
      final file = await controller.synthesizeSpeech(
        model: model,
        text: text,
        options: _speechOptionsFromUi(),
      );
      final duration = await _probeAudioDuration(file.path);
      setState(() {
        generatedAudioPath = file.path;
        if (controller.chatTurns.isNotEmpty &&
            !controller.chatTurns.last.isUser) {
          controller.chatTurns[controller.chatTurns.length -
              1] = ChatTurn.assistant(
            'Generated audio',
            audioPath: file.path,
            duration: duration,
          );
        }
      });
      await _playAudioPath(file.path);
    } catch (error) {
      setState(() => testErrorMessage = '$error');
    } finally {
      setState(() => testBusy = false);
      _scrollChatToBottom();
    }
  }

  Future<void> _runVoicePipeline({
    required InstalledModel asrModel,
    required InstalledModel chatModel,
    required InstalledModel ttsModel,
  }) async {
    final audioPath = selectedAudioPath;
    if (audioPath == null) {
      return;
    }
    setState(() {
      testBusy = true;
      testErrorMessage = null;
      generatedAudioPath = null;
      controller.chatTurns.add(
        ChatTurn.user('Audio: ${p.basename(audioPath)}'),
      );
      controller.chatTurns.add(const ChatTurn.assistant('Transcribing...'));
    });
    _scrollChatToBottom();

    try {
      final transcript = await controller.transcribeAudio(
        model: asrModel,
        audioPath: audioPath,
      );
      setState(() {
        if (controller.chatTurns.isNotEmpty &&
            !controller.chatTurns.last.isUser) {
          controller.chatTurns[controller.chatTurns.length - 1] =
              ChatTurn.assistant('Transcript: $transcript');
        }
        controller.chatTurns.add(ChatTurn.user(transcript));
        controller.chatTurns.add(const ChatTurn.assistant(''));
      });
      _scrollChatToBottom();

      final instruction = chatPromptController.text.trim();
      final voicePrompt =
          '$transcript\n\nInstruction: ${instruction.isEmpty ? 'Answer in the same language as the user. Keep the response concise.' : instruction}';
      final response = await controller.chatRunner.chatStream(
        model: chatModel,
        messages: [LocalChatMessage.user(voicePrompt)],
        params: LocalChatParams(modelId: chatModel.manifest.id),
        onText: _replaceStreamingAssistant,
      );
      final speechFile = await controller.synthesizeSpeech(
        model: ttsModel,
        text: response,
        options: _speechOptionsFromUi(),
      );
      final duration = await _probeAudioDuration(speechFile.path);
      setState(() {
        generatedAudioPath = speechFile.path;
        final lastIndex = controller.chatTurns.lastIndexWhere(
          (turn) => !turn.isUser,
        );
        if (lastIndex != -1) {
          controller.chatTurns[lastIndex] = ChatTurn.assistant(
            response,
            audioPath: speechFile.path,
            duration: duration,
          );
        }
      });
      await _playAudioPath(speechFile.path);
    } catch (error) {
      setState(() => testErrorMessage = '$error');
    } finally {
      setState(() => testBusy = false);
      _scrollChatToBottom();
    }
  }

  SpeechSynthesisOptions _speechOptionsFromUi() {
    return SpeechSynthesisOptions(
      voice: ttsVoiceController.text.trim(),
      instruct: ttsInstructController.text.trim(),
      languageCode: ttsLanguageController.text.trim(),
      referenceAudioPath: ttsReferenceAudioPath,
      speed: double.tryParse(ttsSpeedController.text.trim()),
    );
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

  Future<void> _toggleAudioPlayback(String path) async {
    if (playingAudioPath == path) {
      await audioPlayer.stop();
      if (mounted) {
        setState(() => playingAudioPath = null);
      }
      return;
    }
    await _playAudioPath(path);
  }

  Future<void> _playAudioPath(String path) async {
    await audioPlayer.stop();
    await audioPlayer.play(DeviceFileSource(path));
    if (!mounted) {
      return;
    }
    setState(() => playingAudioPath = path);
    audioPlayer.onPlayerComplete.first.then((_) {
      if (mounted && playingAudioPath == path) {
        setState(() => playingAudioPath = null);
      }
    });
  }

  Future<Duration?> _probeAudioDuration(String path) async {
    await audioPlayer.setSource(DeviceFileSource(path));
    return audioPlayer.getDuration();
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _runtimeConfigSummary(ModelRuntimeConfig config) {
    final parts = <String>[];
    if (config.voices.isNotEmpty) {
      parts.add(
        'Voices: ${config.voices.take(3).map((voice) => voice.displayName).join(', ')}${config.voices.length > 3 ? '…' : ''}',
      );
    }
    final mediaType = config.output['media_type'];
    final defaultSize = config.output['default_size'];
    if (mediaType != null) {
      parts.add('Output: $mediaType');
    }
    if (defaultSize != null) {
      parts.add('Size: $defaultSize');
    }
    final defaults = config.defaultParameters.entries
        .where(
          (entry) => entry.key != 'audio_format' && entry.key != 'join_audio',
        )
        .take(4)
        .map((entry) => '${entry.key}: ${entry.value}')
        .join(', ');
    if (defaults.isNotEmpty) {
      parts.add('Defaults: $defaults');
    }
    return parts.join(' • ');
  }

  Widget _buildModelCardDetails(BuildContext context, ModelCard card) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      dense: true,
      title: const Text('Model description'),
      subtitle: card.summary.isEmpty ? null : Text(card.summary),
      children: [
        if (card.useCases.isNotEmpty)
          _buildModelCardLine('Use cases', card.useCases.join(', ')),
        if (card.languages.isNotEmpty)
          _buildModelCardLine('Languages', card.languages.join(', ')),
        if (card.limitations.isNotEmpty)
          _buildModelCardLine('Limits', card.limitations.join(', ')),
        if (card.tags.isNotEmpty)
          _buildModelCardLine('Tags', card.tags.join(', ')),
      ],
    );
  }

  Widget _buildModelCardLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
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
    if (model.imageGenerationSupported) {
      return 'image generation';
    }
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

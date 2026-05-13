import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:local_models_flutter/local_models_flutter.dart';
import 'package:local_models_sdk/local_models_sdk.dart' as sdk;
import 'package:local_models_studio/studio/studio_types.dart';
import 'package:local_models_studio/studio/widgets/studio_svg_icon.dart';
import 'package:local_models_studio/studio/widgets/thinking_indicator.dart';
import 'package:local_models_studio/voice_pipeline_cubit.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

enum _TestInputMode { text, audio, image }

enum _TestWorkspaceMode { single, voicePipeline, e2eBenchmark }

enum _E2eBenchmarkStatus { running, passed, failed, skipped }

class _BenchmarkRunOutput {
  const _BenchmarkRunOutput({required this.duration, required this.output});

  final Duration duration;
  final String output;
}

class _E2eBenchmarkResult {
  _E2eBenchmarkResult({required this.modelName, required this.task});

  final String modelName;
  final String task;
  _E2eBenchmarkStatus status = _E2eBenchmarkStatus.running;
  Duration? coldStartDuration;
  Duration? secondRunDuration;
  String? output;
  String? error;
}

T? _firstWhereOrNull<T>(Iterable<T> values, bool Function(T value) test) {
  for (final value in values) {
    if (test(value)) {
      return value;
    }
  }
  return null;
}

/// Default editable sample for the Tools JSON field (array of [LocalTool] maps).
const String kDefaultStudioToolsJsonSample = r'''
[
  {
    "name": "get_current_time",
    "description": "Returns the current local time as an ISO-8601 string.",
    "parametersJsonSchema": {
      "type": "object",
      "properties": {
        "timezone": {
          "type": "string",
          "description": "IANA timezone id (optional), e.g. America/New_York"
        }
      }
    }
  },
  {
    "name": "echo_message",
    "description": "Demo tool: echoes the message (Studio stub handler).",
    "parametersJsonSchema": {
      "type": "object",
      "properties": {
        "message": {
          "type": "string",
          "description": "Short text to echo"
        }
      },
      "required": ["message"]
    }
  }
]
''';

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
  late final TextEditingController chatToolsJsonController;
  late final TextEditingController ttsVoiceController;
  late final TextEditingController ttsInstructController;
  late final TextEditingController ttsLanguageController;
  late final TextEditingController ttsSpeedController;
  late final TextEditingController ttsReferenceTextController;
  late final TextEditingController generationMaxTokensController;
  late final TextEditingController generationTemperatureController;
  late final TextEditingController generationTopPController;
  late final ScrollController chatScrollController;
  late final AudioRecorder audioRecorder;
  late final AudioPlayer audioPlayer;
  late final VoicePipelineCubit _voicePipelineCubit;
  InstalledModel? selectedTestModel;
  InstalledModel? selectedAsrModel;
  InstalledModel? selectedVoiceChatModel;
  InstalledModel? selectedTtsModel;
  String? selectedAudioPath;
  String? selectedImagePath;
  String? ttsReferenceAudioPath;
  String? myVoiceReferencePath;
  bool _ttsCloneMode = false;
  // For VoiceDesign models: true = use speaker preset, false = use design prompt.
  bool _ttsVoiceDesignUsesPreset = false;
  String? generatedAudioPath;
  String? playingAudioPath;
  bool audioInputMode = false;
  bool imageInputMode = false;
  _TestWorkspaceMode testWorkspaceMode = _TestWorkspaceMode.single;
  bool recordingAudio = false;
  bool recordingReferenceVoice = false;
  bool transcribingReferenceVoice = false;
  late final ModelRuntimePreferencesStore _prefsStore;
  late final TextEditingController streamingTtsEndpointController;
  late final TextEditingController streamingTtsModelIdController;
  bool streamSpeechEnabled = false;
  bool generationThinkingEnabled = false;
  bool testBusy = false;
  sdk.Voice2VoiceCancelToken? _voicePipelineCancel;
  String? testErrorMessage;
  bool chatToolsExpanded = false;
  bool obscureHfToken = true;
  bool settingsControllersHydrated = false;
  int selectedPageIndex = 0;
  String catalogFilter = 'all';
  final List<_E2eBenchmarkResult> e2eBenchmarkResults = <_E2eBenchmarkResult>[];

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
    _prefsStore = ModelRuntimePreferencesStore(paths: controller.paths);
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
    chatToolsJsonController = TextEditingController(
      text: kDefaultStudioToolsJsonSample.trim(),
    );
    ttsVoiceController = TextEditingController();
    ttsInstructController = TextEditingController(
      text: 'A calm, natural assistant voice with stable tone.',
    );
    ttsLanguageController = TextEditingController(text: 'auto');
    ttsSpeedController = TextEditingController(text: '1.0');
    ttsReferenceTextController = TextEditingController();
    generationMaxTokensController = TextEditingController(text: '256');
    generationTemperatureController = TextEditingController(text: '0.7');
    generationTopPController = TextEditingController(text: '0.95');
    chatScrollController = ScrollController();
    streamingTtsEndpointController = TextEditingController();
    streamingTtsModelIdController = TextEditingController();
    audioRecorder = AudioRecorder();
    audioPlayer = AudioPlayer();
    _voicePipelineCubit = VoicePipelineCubit();
    controller.addListener(_handleControllerUpdate);
    unawaited(controller.initialize());
    unawaited(_loadLatestVoiceReference());
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await audioRecorder.stop();
      } catch (_) {}
      if (mounted) {
        setState(() {
          recordingAudio = false;
          recordingReferenceVoice = false;
        });
      }
    });
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
    chatToolsJsonController.dispose();
    ttsVoiceController.dispose();
    ttsInstructController.dispose();
    ttsLanguageController.dispose();
    ttsSpeedController.dispose();
    ttsReferenceTextController.dispose();
    generationMaxTokensController.dispose();
    generationTemperatureController.dispose();
    generationTopPController.dispose();
    chatScrollController.dispose();
    streamingTtsEndpointController.dispose();
    streamingTtsModelIdController.dispose();
    audioRecorder.dispose();
    audioPlayer.dispose();
    _voicePipelineCubit.close();
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

  Future<void> _loadLatestVoiceReference() async {
    final file = _bestVoiceReferenceFile();
    if (file == null || !mounted) {
      return;
    }
    setState(() {
      myVoiceReferencePath = file.path;
      ttsReferenceAudioPath = file.path;
      final sidecar = File(p.setExtension(file.path, '.txt'));
      if (sidecar.existsSync()) {
        final transcript = sidecar.readAsStringSync().trim();
        if (transcript.isNotEmpty) {
          ttsReferenceTextController.text = transcript;
        }
      }
    });
  }

  List<File> _voiceReferenceFiles() {
    final directory = controller.paths.voiceReferencesDirectory;
    if (!directory.existsSync()) {
      return const <File>[];
    }
    return directory.listSync().whereType<File>().where((file) {
      final extension = p.extension(file.path).toLowerCase();
      return <String>{
        '.wav',
        '.mp3',
        '.m4a',
        '.aac',
        '.flac',
        '.ogg',
      }.contains(extension);
    }).toList()..sort(
      (left, right) =>
          right.lastModifiedSync().compareTo(left.lastModifiedSync()),
    );
  }

  File? _bestVoiceReferenceFile() {
    final files = _voiceReferenceFiles();
    if (files.isEmpty) {
      return null;
    }
    for (final file in files) {
      if (_hasReferenceTranscript(file.path)) {
        return file;
      }
    }
    return files.first;
  }

  bool _hasReferenceTranscript(String audioPath) {
    final sidecar = File(p.setExtension(audioPath, '.txt'));
    if (!sidecar.existsSync()) {
      return false;
    }
    return sidecar.readAsStringSync().trim().isNotEmpty;
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
    return BlocProvider.value(
      value: _voicePipelineCubit,
      child: Scaffold(
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
                  icon: StudioSvgIcon('sparkle', opacity: 0.6),
                  selectedIcon: StudioSvgIcon('sparkle'),
                  label: Text('E2E'),
                ),
                NavigationRailDestination(
                  icon: StudioSvgIcon('mic', opacity: 0.6),
                  selectedIcon: StudioSvgIcon('mic'),
                  label: Text('Voices'),
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
                          child: const Text('Flutter SDK demo · UI May 2026'),
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
                  Expanded(child: _buildActivePage(context)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActivePage(BuildContext context) {
    switch (selectedPageIndex) {
      case 0:
        return _buildCatalogTab(context);
      case 1:
        return _buildDownloadsTab(context);
      case 2:
        return _buildTestTab(context);
      case 3:
        return _buildE2eBenchmarkTab(
          context,
          installedModels: controller.installedModels,
          showModeSwitch: false,
        );
      case 4:
        return _buildVoicesTab(context);
      case 5:
        return _buildSettingsTab(context);
      default:
        return _buildCatalogTab(context);
    }
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
        Row(
          children: [
            Expanded(
              child: Text(
                'Installed Models (${controller.installedModels.length})',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            OutlinedButton.icon(
              onPressed: controller.installedModels.isEmpty
                  ? null
                  : () => _runAction(_refreshAllInstalledModelMetadata),
              icon: const StudioSvgIcon('refresh', size: 20),
              label: const Text('Update Configs'),
            ),
          ],
        ),
        if (controller.installedModels.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('Total disk usage: ${formatBytes(installedBytes)}'),
        ],
        if (controller.metadataStatusMessage.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(controller.metadataStatusMessage),
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

  Widget _buildVoicesTab(BuildContext context) {
    final files = _voiceReferenceFiles();
    final selectedPath = myVoiceReferencePath;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'My Voices',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Record a clean 3–10 sec sample once, then reuse it as Ref Audio for Qwen3 TTS Base voice cloning.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: testBusy || recordingAudio
                  ? null
                  : recordingReferenceVoice
                  ? _stopReferenceVoiceRecording
                  : _startReferenceVoiceRecording,
              icon: StudioSvgIcon(
                recordingReferenceVoice ? 'stop' : 'mic',
                size: 20,
              ),
              label: Text(
                recordingReferenceVoice ? 'Stop Recording' : 'Record My Voice',
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: testBusy || recordingReferenceVoice
                  ? null
                  : _importVoiceReferenceAudioFile,
              icon: const StudioSvgIcon('folder', size: 20),
              label: const Text('Import Audio'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  selectedPath == null
                      ? 'No active voice selected'
                      : 'Active voice: ${p.basename(selectedPath)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SelectableText(
                  selectedPath ?? 'Record or import a sample below.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ttsReferenceTextController,
                  enabled: !testBusy,
                  minLines: 1,
                  maxLines: 2,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Reference transcript',
                    hintText:
                        'Optional but recommended: text spoken in your voice sample.',
                    prefixIcon: Padding(
                      padding: EdgeInsets.all(12),
                      child: StudioSvgIcon('chat', size: 20),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton.icon(
                      onPressed: selectedPath == null
                          ? null
                          : () => _toggleAudioPlayback(selectedPath),
                      icon: StudioSvgIcon(
                        playingAudioPath == selectedPath ? 'stop' : 'play',
                        size: 20,
                      ),
                      label: Text(
                        playingAudioPath == selectedPath ? 'Stop' : 'Play',
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: selectedPath == null
                          ? null
                          : () => unawaited(
                              _selectVoiceReference(
                                selectedPath,
                                openTest: true,
                              ),
                            ),
                      icon: const StudioSvgIcon('mic', size: 20),
                      label: const Text('Use in Test'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text('Saved Samples', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (files.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No saved voice samples yet.'),
            ),
          )
        else
          ...files.map(
            (file) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _buildVoiceReferenceCard(file),
            ),
          ),
      ],
    );
  }

  Widget _buildVoiceReferenceCard(File file) {
    final selected = myVoiceReferencePath == file.path;
    final isPlaying = playingAudioPath == file.path;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            StudioSvgIcon(selected ? 'mic' : 'audio', size: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${p.basename(file.path)}${selected ? ' • active' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${formatBytes(file.lengthSync())} • ${file.lastModifiedSync()}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: () => _toggleAudioPlayback(file.path),
              icon: StudioSvgIcon(isPlaying ? 'stop' : 'play', size: 20),
              label: Text(isPlaying ? 'Stop' : 'Play'),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: () => unawaited(_selectVoiceReference(file.path)),
              icon: const StudioSvgIcon('mic', size: 20),
              label: const Text('Use Voice'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTestTab(BuildContext context) {
    final installedModels = controller.installedModels;
    final selectedModel = installedModels.contains(selectedTestModel)
        ? selectedTestModel
        : installedModels.isEmpty
        ? null
        : installedModels.first;
    // Audio test UX: dedicated mlx-audio ASR models always; VLM audio only when
    // session settings set Input modality to Audio (not merely speechToTextSupported,
    // which Gemma reports for its audio-input capability even in Text mode).
    final useAudioInput =
        selectedModel != null &&
        (selectedModel.dedicatedSpeechToTextModel ||
            (selectedModel.audioPromptSupported && audioInputMode));
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
        (selectedModel.speechToTextSupported ||
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

    if (testWorkspaceMode == _TestWorkspaceMode.e2eBenchmark) {
      return _buildE2eBenchmarkTab(context, installedModels: installedModels);
    }

    if (testWorkspaceMode == _TestWorkspaceMode.voicePipeline) {
      return _buildVoicePipelineTab(
        context,
        asrModels: asrModels,
        chatModels: voiceChatModels,
        ttsModels: ttsModels,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTestModeSwitch(),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primaryContainer.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.settings_suggest_outlined,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Use the gear (⚙) next to the model name for local path, LLM '
                    'parameters, VLM text/audio/image mode, and the full TTS panel '
                    '(Speaker list for CustomVoice, reference cloning, transcripts).',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(height: 1.35),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (installedModels.isEmpty)
            Text(
              'Install a model from Catalog to run tests.',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            )
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<InstalledModel>(
                    key: ValueKey<String>(
                      'test_model_${selectedModel?.manifest.id ?? "none"}',
                    ),
                    isDense: true,
                    initialValue: selectedModel,
                    decoration: const InputDecoration(
                      labelText: 'Model',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    items: installedModels
                        .map(
                          (model) => DropdownMenuItem<InstalledModel>(
                            value: model,
                            child: Text(
                              '${model.manifest.displayName} (${_testModeLabel(model)})',
                              overflow: TextOverflow.ellipsis,
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
                        if (value?.textPromptSupported == true) {
                          _applyGenerationDefaultsForModel(value);
                        }
                        if (value?.textToSpeechSupported == true) {
                          _applyTtsDefaultsForModel(value);
                        }
                      });
                      controller.clearChat();
                    },
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip:
                      'Model path, generation tuning, input mode, speech voice',
                  onPressed: selectedModel == null || testBusy
                      ? null
                      : () => unawaited(
                          _openTestSessionSettingsDialog(
                            context,
                            selectedModel: selectedModel,
                          ),
                        ),
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ),
            if (selectedModel?.manifest.runtimeAdapter ==
                    RuntimeAdapter.mlxVlm &&
                selectedModel?.textPromptSupported == true) ...[
              const SizedBox(height: 6),
              Text(
                'VLM input mode (text / audio / image) is in session settings.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
          ],
          if (selectedModel != null &&
              _modelSupportsToolCallingUi(selectedModel)) ...[
            const SizedBox(height: 10),
            _buildChatToolsCompactPanel(selectedModel),
          ],
          if (testErrorMessage != null) ...[
            const SizedBox(height: 10),
            _buildSelectableError(testErrorMessage!),
          ],
          const SizedBox(height: 12),
          Expanded(child: _buildConversationPane(context)),
          Flexible(
            fit: FlexFit.loose,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  if (useSpeechOutput && selectedModel != null) ...[
                    _buildTtsVoicePanel(selectedModel, forDialog: false),
                    const SizedBox(height: 10),
                  ],
                  if (useAudioInput)
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
                            hintText:
                                'Ask what the model should do with the image...',
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
                      enabled:
                          !testBusy &&
                          (useSpeechOutput
                              ? selectedModel != null
                              : selectedModel?.textPromptSupported == true),
                      decoration: InputDecoration(
                        labelText: useSpeechOutput ? 'Speech text' : 'Message',
                        border: const OutlineInputBorder(),
                        helperText:
                            useSpeechOutput &&
                                selectedModel != null &&
                                chatPromptController.text.trim().isEmpty
                            ? 'Type text here to enable Generate Speech.'
                            : null,
                        hintText: selectedModel == null
                            ? 'Install a model first'
                            : useSpeechOutput
                            ? 'Type text to synthesize locally...'
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
                      if (useAudioInput)
                        FilledButton.icon(
                          onPressed: canSendAudio
                              ? () => _sendAudioToSelectedModel(selectedModel)
                              : null,
                          icon: testBusy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
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
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const StudioSvgIcon('mic', size: 22),
                          label: Text(
                            testBusy ? 'Running...' : 'Generate Speech',
                          ),
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
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const StudioSvgIcon('send', size: 22),
                          label: Text(testBusy ? 'Running...' : 'Send Image'),
                        )
                      else if (useImageGeneration && selectedModel != null)
                        FilledButton.icon(
                          onPressed: canGenerateImage
                              ? () => _generateImageWithSelectedModel(
                                  selectedModel,
                                )
                              : null,
                          icon: testBusy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const StudioSvgIcon('image', size: 22),
                          label: Text(
                            testBusy ? 'Generating...' : 'Generate Image',
                          ),
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
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
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
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatTurnBody(ChatTurn turn) {
    if (_isAssistantThinking(turn)) {
      return const ThinkingIndicator();
    }
    final imagePath = turn.imagePath;
    final audioPath = turn.audioPath;
    if (imagePath == null && audioPath == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(turn.message),
          if (turn.progress != null) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: turn.progress),
          ],
          _buildGenerationTimeFooter(turn),
        ],
      );
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
          _buildGenerationTimeFooter(turn),
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
        _buildGenerationTimeFooter(turn),
      ],
    );
  }

  Widget _buildGenerationTimeFooter(ChatTurn turn) {
    final duration = turn.generationDuration;
    if (duration == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        'Generated in ${_formatGenerationDuration(duration)}',
        style: TextStyle(
          color: Theme.of(context).colorScheme.outline,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildTestModeSwitch() {
    final segmented = SegmentedButton<_TestWorkspaceMode>(
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
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
        ButtonSegment<_TestWorkspaceMode>(
          value: _TestWorkspaceMode.e2eBenchmark,
          icon: StudioSvgIcon('sparkle', size: 20),
          label: Text('E2E Bench'),
        ),
      ],
      selected: <_TestWorkspaceMode>{testWorkspaceMode},
      onSelectionChanged: (selection) {
        unawaited(_applyTestWorkspaceMode(selection.first));
      },
    );

    if (recordingAudio || recordingReferenceVoice) {
      const hint =
          'Recording in progress: switching modes stops it (same as Stop).';
      return Tooltip(message: hint, child: segmented);
    }
    return segmented;
  }

  Future<void> _applyTestWorkspaceMode(_TestWorkspaceMode next) async {
    if (recordingAudio) {
      await _stopAudioRecording(runVoicePipelineOnStop: false);
    }
    if (recordingReferenceVoice) {
      await _stopReferenceVoiceRecording();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      testWorkspaceMode = next;
      testErrorMessage = null;
    });
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
        !recordingReferenceVoice &&
        !testBusy;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTestModeSwitch(),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: LayoutBuilder(
              builder: (context, _) {
                final maxH = (MediaQuery.sizeOf(context).height * 0.46)
                    .clamp(240.0, 540.0);
                return ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxH),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Voice pipeline',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Pick ASR, chat, and TTS models. Use ⚙ on each row for path, tools (chat), voices (TTS), and streaming.',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'TTS ⚙ also has optional OpenAI-compatible streaming. Record your reference under My Voices.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: testBusy || recordingAudio
                            ? null
                            : () => setState(() => selectedPageIndex = 4),
                        icon: const StudioSvgIcon('mic', size: 20),
                        label: const Text('My Voices'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _buildVoicePipelineModelRow(
                          label: 'ASR model',
                          icon: const StudioSvgIcon('audio', size: 22),
                          models: asrModels,
                          value: asrModel,
                          emptyText: 'Install a speech-to-text model',
                          settingsTooltip:
                              'ASR model path (and session fields if available)',
                          onChanged: (value) =>
                              setState(() => selectedAsrModel = value),
                          onOpenSettings: asrModel == null
                              ? null
                              : () => unawaited(
                                    _openTestSessionSettingsDialog(
                                      context,
                                      selectedModel: asrModel,
                                    ),
                                  ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildVoicePipelineModelRow(
                          label: 'Response model',
                          icon: const StudioSvgIcon('chat', size: 22),
                          models: chatModels,
                          value: chatModel,
                          emptyText: 'Install a chat model',
                          settingsTooltip:
                              'Generation, LLM tools (JSON), model folder',
                          onChanged: (value) {
                            setState(() {
                              selectedVoiceChatModel = value;
                              _applyGenerationDefaultsForModel(value);
                              _applyStoredPrefsForChatModel(value);
                            });
                          },
                          onOpenSettings: chatModel == null
                              ? null
                              : () => unawaited(
                                    _openTestSessionSettingsDialog(
                                      context,
                                      selectedModel: chatModel,
                                      voicePipelineSuppressVlmInput: true,
                                      persistGenerationPrefsOnDone: true,
                                    ),
                                  ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildVoicePipelineModelRow(
                          label: 'TTS model',
                          icon: const StudioSvgIcon('mic', size: 22),
                          models: ttsModels,
                          value: ttsModel,
                          emptyText: 'Install a text-to-speech model',
                          settingsTooltip:
                              'Voice, clone, remote streaming TTS',
                          onChanged: (value) {
                            setState(() {
                              selectedTtsModel = value;
                              _applyTtsDefaultsForModel(value);
                              _applyStoredPrefsForTtsModel(value);
                            });
                          },
                          onOpenSettings: ttsModel == null
                              ? null
                              : () => unawaited(
                                    _openVoicePipelineSettingsDialog(
                                      context,
                                      ttsModel: ttsModel,
                                    ),
                                  ),
                        ),
                      ),
                    ],
                  ),
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
                    _buildSelectableError(testErrorMessage!),
                  ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Expanded(child: _buildConversationPane(context)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              BlocBuilder<VoicePipelineCubit, VoicePipelinePhase>(
                builder: (context, phase) {
                  return Tooltip(
                    message:
                        'Voice UX runs the full loop on the selected audio: ASR → new model reply '
                        '→ new TTS. This is not "replay last message": with temperature > 0, text '
                        'and prosody can differ each run. Console: [VoiceUX], [VoiceUX:chain].',
                    child: FilledButton.icon(
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
                      label: Text(_voicePipelinePrimaryLabel(phase)),
                    ),
                  );
                },
              ),
              if (testBusy)
                OutlinedButton.icon(
                  onPressed: () => _voicePipelineCancel?.cancel(),
                  icon: const Icon(Icons.stop_circle_outlined, size: 22),
                  label: const Text('Stop'),
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

  Widget _buildE2eBenchmarkTab(
    BuildContext context, {
    required List<InstalledModel> installedModels,
    bool showModeSwitch = true,
  }) {
    final candidates = installedModels
        .where(_isE2eBenchmarkModel)
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showModeSwitch) ...[
            _buildTestModeSwitch(),
            const SizedBox(height: 12),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'E2E local benchmark',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Runs prepared prompts 1-by-1 across installed chat/TTS models and records cold start + immediate second run.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          candidates.isEmpty
                              ? 'Install at least one chat or text-to-speech model.'
                              : '${candidates.length} model(s) ready: ${candidates.map((model) => model.manifest.displayName).take(4).join(', ')}${candidates.length > 4 ? '…' : ''}',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  FilledButton.icon(
                    onPressed: testBusy || candidates.isEmpty
                        ? null
                        : () => _runE2eBenchmark(candidates),
                    icon: testBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const StudioSvgIcon('play', size: 22),
                    label: Text(testBusy ? 'Running...' : 'Run E2E'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: testBusy || e2eBenchmarkResults.isEmpty
                        ? null
                        : () => setState(e2eBenchmarkResults.clear),
                    icon: const StudioSvgIcon('trash', size: 20),
                    label: const Text('Clear'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: e2eBenchmarkResults.isEmpty
                ? Card(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const StudioSvgIcon('sparkle', size: 48),
                            const SizedBox(height: 12),
                            Text(
                              'Press Run E2E to catch runtime issues like missing audio output before you manually test models.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: e2eBenchmarkResults.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) =>
                        _buildE2eResultCard(e2eBenchmarkResults[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildE2eResultCard(_E2eBenchmarkResult result) {
    final statusColor = _e2eStatusColor(result.status);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${result.modelName} • ${result.task}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.55),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Text(
                    _e2eStatusLabel(result.status),
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              [
                'Cold: ${_formatOptionalDuration(result.coldStartDuration)}',
                'Second: ${_formatOptionalDuration(result.secondRunDuration)}',
              ].join(' • '),
            ),
            if (result.output != null && result.output!.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              SelectableText(result.output!),
            ],
            if (result.error != null && result.error!.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              _buildSelectableError(result.error!),
            ],
          ],
        ),
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
        final isThinking = _isAssistantThinking(turn);
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
                color: isThinking ? null : color,
                gradient: isThinking
                    ? const LinearGradient(
                        colors: [Color(0xFF2B2F52), Color(0xFF252947)],
                      )
                    : null,
                borderRadius: BorderRadius.circular(22),
                border: isThinking
                    ? Border.all(color: const Color(0xFF555B86))
                    : null,
                boxShadow: isThinking
                    ? [
                        BoxShadow(
                          color: const Color(
                            0xFF8F6BFF,
                          ).withValues(alpha: 0.12),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ]
                    : null,
              ),
              padding: isThinking
                  ? const EdgeInsets.symmetric(horizontal: 16, vertical: 14)
                  : const EdgeInsets.all(18),
              child: _buildChatTurnBody(turn),
            ),
          ],
        );
      },
    );
  }

  bool _isAssistantThinking(ChatTurn turn) {
    return !turn.isUser &&
        turn.message.trim().isEmpty &&
        turn.audioPath == null &&
        turn.imagePath == null &&
        turn.progress == null;
  }

  Widget _buildVoicePipelineModelRow({
    required String label,
    required Widget icon,
    required List<InstalledModel> models,
    required InstalledModel? value,
    required String emptyText,
    required ValueChanged<InstalledModel?> onChanged,
    required String settingsTooltip,
    required VoidCallback? onOpenSettings,
  }) {
    final busyFlag = testBusy || recordingAudio || recordingReferenceVoice;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _buildModelDropdown(
            label: label,
            icon: icon,
            models: models,
            value: value,
            emptyText: emptyText,
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 2),
        IconButton(
          tooltip: settingsTooltip,
          onPressed: busyFlag || onOpenSettings == null ? null : onOpenSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    );
  }

  sdk.VoiceTtsCoalescing _voicePipelineTtsCoalescing(InstalledModel ttsModel) {
    final extra = ttsModel.manifest.runtimeConfig.extra;
    final mode = extra['qwen_tts_mode'] as String? ?? '';
    final id = ttsModel.manifest.id.toLowerCase();
    if (mode == 'voice_design' ||
        mode == 'base' ||
        extra['supports_voice_clone'] == true ||
        id.contains('voxcpm')) {
      return const sdk.VoiceTtsCoalescing.singleUtterancePerReply();
    }
    return const sdk.VoiceTtsCoalescing();
  }

  String _voiceUxTtsCoalescingLabel(sdk.VoiceTtsCoalescing c) {
    if (c.flushEveryDelta) {
      return 'immediate (each delta)';
    }
    if (c.maxCharsPerSegment >= 100000) {
      return 'singleUtterancePerReply (one local TTS call per reply)';
    }
    return 'phraseCoalesce (maxChars=${c.maxCharsPerSegment})';
  }

  String _voiceUxPreview(String text, int maxChars) {
    final single = text.replaceAll('\n', ' ').trim();
    if (single.length <= maxChars) {
      return single;
    }
    return '${single.substring(0, maxChars)}…';
  }

  void _voiceUxLog(String message) {
    debugPrint('[VoiceUX] $message');
  }

  String _voicePipelinePrimaryLabel(VoicePipelinePhase phase) {
    if (!testBusy) {
      return 'Run Voice UX';
    }
    switch (phase) {
      case VoicePipelinePhase.transcribing:
        return 'Transcribing…';
      case VoicePipelinePhase.replying:
        return 'Model replying…';
      case VoicePipelinePhase.synthesizing:
        return 'Generating speech…';
      case VoicePipelinePhase.idle:
        return 'Working…';
    }
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

  Widget _buildTtsVoiceCompactSummaryBar(
    InstalledModel model, {
    required VoidCallback onOpenSettings,
  }) {
    final config = model.manifest.runtimeConfig;
    final voiceNames = _ttsVoiceOptions(config);
    final mode = config.extra['qwen_tts_mode'] as String? ?? '';
    final needsQuickSpeakerPick = voiceNames.isNotEmpty;
    final voicePickOptions = _withCurrentOption(
      voiceNames,
      ttsVoiceController.text.trim(),
    );
    final voicePickValue =
        voicePickOptions.contains(ttsVoiceController.text.trim()) &&
            ttsVoiceController.text.trim().isNotEmpty
        ? ttsVoiceController.text.trim()
        : voicePickOptions.first;
    final activeVoiceLabel = ttsReferenceAudioPath != null
        ? p.basename(ttsReferenceAudioPath!)
        : ttsVoiceController.text.trim().isNotEmpty
        ? ttsVoiceController.text.trim()
        : mode == 'base'
        ? 'No reference voice'
        : 'Preset / default';
    final compactSummary = [
      activeVoiceLabel,
      'Language ${ttsLanguageController.text.trim().isEmpty ? 'auto' : ttsLanguageController.text.trim()}',
      'Speed ${ttsSpeedController.text.trim().isEmpty ? '1.0' : ttsSpeedController.text.trim()}',
    ].join(' • ');
    return Material(
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: StudioSvgIcon(
                'mic',
                size: 20,
                opacity: Theme.of(context).brightness == Brightness.dark
                    ? 0.9
                    : 0.85,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Speech voice',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    compactSummary,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                      height: 1.25,
                    ),
                  ),
                  if (mode == 'voice_design' && voiceNames.isEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'VoiceDesign uses your prompt + reference audio, not a preset '
                      'speaker list. For built-in names (Vivian, Ryan, …) install '
                      'Qwen3 TTS CustomVoice and pick it as the model.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.secondary,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (needsQuickSpeakerPick && !_ttsReferenceCloneReadySync()) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: 210,
                child: DropdownButtonFormField<String>(
                  key: ValueKey<String>('tts_compact_speaker_$voicePickValue'),
                  initialValue: voicePickValue,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'Speaker',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                  items: voicePickOptions
                      .map(
                        (v) => DropdownMenuItem<String>(
                          value: v,
                          child: Text(
                            _prettyTtsOption(v),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: testBusy
                      ? null
                      : (value) => setState(
                          () => ttsVoiceController.text = value ?? '',
                        ),
                ),
              ),
            ],
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: testBusy ? null : onOpenSettings,
              icon: const Icon(Icons.tune, size: 20),
              label: const Text('Voice & model'),
            ),
          ],
        ),
      ),
    );
  }

  bool _ttsReferenceCloneReadySync() {
    final path = ttsReferenceAudioPath?.trim();
    if (path == null || path.isEmpty) {
      return false;
    }
    if (!File(path).existsSync()) {
      return false;
    }
    return ttsReferenceTextController.text.trim().isNotEmpty;
  }

  /// Full TTS controls for dialogs. Compact bar for the test workspace.
  Widget _buildTtsVoicePanel(
    InstalledModel? model, {
    required bool forDialog,
    VoidCallback? onMyVoices,
    VoidCallback? dialogRefresh,
  }) {
    if (model == null) {
      return const SizedBox.shrink();
    }
    if (!forDialog) {
      return _buildTtsVoiceCompactSummaryBar(
        model,
        onOpenSettings: () => unawaited(
          _openTestSessionSettingsDialog(context, selectedModel: model),
        ),
      );
    }
    final config = model.manifest.runtimeConfig;
    final voiceNames = _ttsVoiceOptions(config);
    final languageOptions = _ttsLanguageOptions(config);
    final speedOptions = _withCurrentOption(const <String>[
      '0.75',
      '0.9',
      '1.0',
      '1.1',
      '1.25',
      '1.5',
    ], ttsSpeedController.text.trim());
    final mode = config.extra['qwen_tts_mode'] as String? ?? '';
    final vibevoiceMode = config.extra['vibevoice_tts_mode'] as String? ?? '';
    final isVoiceDesign = mode == 'voice_design';
    final isVibeVoice = vibevoiceMode.isNotEmpty;
    final hasPresets = voiceNames.isNotEmpty;
    // Clone mode: user explicitly switched or a ref file is already set.
    final inCloneMode = _ttsCloneMode || ttsReferenceAudioPath != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header ──────────────────────────────────────────────────────────
        Row(
          children: [
            Text(
              'Speech synthesis',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            if (onMyVoices != null)
              OutlinedButton.icon(
                onPressed: testBusy ? null : onMyVoices,
                icon: const StudioSvgIcon('mic', size: 18),
                label: const Text('My Voices'),
              ),
          ],
        ),
        const SizedBox(height: 16),

        // ── Voice source ─────────────────────────────────────────────────────
        if (isVibeVoice) ...[
          // VibeVoice Realtime: preset voices only (no clone, no instruct)
          _buildStringComboBox(
            label: 'Speaker',
            value: ttsVoiceController.text.trim(),
            options: hasPresets
                ? voiceNames
                : const ['en-Emma_woman', 'Carter'],
            icon: const StudioSvgIcon('mic', size: 20),
            onChanged: (value) {
              setState(() => ttsVoiceController.text = value ?? '');
              dialogRefresh?.call();
            },
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.secondaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.secondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'VibeVoice Realtime uses Python mlx-audio for inference. '
                    'Voice cloning is not available for this model.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ] else if (isVoiceDesign) ...[
          // VoiceDesign: user can pick a preset OR write a design prompt
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(
                value: false,
                label: Text('Design prompt'),
                icon: Icon(Icons.text_fields_rounded),
              ),
              ButtonSegment<bool>(
                value: true,
                label: Text('Preset voice'),
                icon: Icon(Icons.record_voice_over_outlined),
              ),
            ],
            selected: {_ttsVoiceDesignUsesPreset},
            onSelectionChanged: testBusy
                ? null
                : (sel) {
                    setState(() => _ttsVoiceDesignUsesPreset = sel.first);
                    dialogRefresh?.call();
                  },
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
          const SizedBox(height: 16),
          if (_ttsVoiceDesignUsesPreset) ...[
            // ── Preset tab for VoiceDesign ──────────────────────────────────
            _buildStringComboBox(
              label: 'Speaker',
              value: ttsVoiceController.text.trim(),
              options: voiceNames,
              icon: const StudioSvgIcon('mic', size: 20),
              onChanged: (value) {
                setState(() => ttsVoiceController.text = value ?? '');
                dialogRefresh?.call();
              },
            ),
          ] else ...[
            // ── Design prompt tab ───────────────────────────────────────────
            TextField(
              controller: ttsInstructController,
              enabled: !testBusy,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) {
                setState(() {});
                dialogRefresh?.call();
              },
              decoration: const InputDecoration(
                labelText: 'Voice design prompt',
                hintText:
                    'Describe the voice: calm, deep, Russian female, speaking clearly...',
              ),
            ),
          ],
          const SizedBox(height: 20),
          // Optional clone section
          Row(
            children: [
              Text(
                'Clone timbre from audio',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(width: 8),
              Text(
                '(optional)',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildCloneAudioFields(dialogRefresh),
        ] else if (hasPresets) ...[
          // CustomVoice / Base with presets: Preset vs Clone toggle
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(
                value: false,
                label: Text('Preset voice'),
                icon: Icon(Icons.record_voice_over_outlined),
              ),
              ButtonSegment<bool>(
                value: true,
                label: Text('Clone from audio'),
                icon: Icon(Icons.mic_outlined),
              ),
            ],
            selected: {inCloneMode},
            onSelectionChanged: testBusy
                ? null
                : (sel) {
                    final clone = sel.first;
                    setState(() {
                      _ttsCloneMode = clone;
                      if (!clone) {
                        ttsReferenceAudioPath = null;
                        ttsReferenceTextController.clear();
                      }
                    });
                    dialogRefresh?.call();
                  },
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
          const SizedBox(height: 16),
          if (!inCloneMode) ...[
            // ── Preset tab ────────────────────────────────────────────────
            _buildStringComboBox(
              label: 'Speaker',
              value: ttsVoiceController.text.trim(),
              options: voiceNames,
              icon: const StudioSvgIcon('mic', size: 20),
              onChanged: (value) {
                setState(() => ttsVoiceController.text = value ?? '');
                dialogRefresh?.call();
              },
            ),
            if (mode == 'custom_voice') ...[
              const SizedBox(height: 12),
              TextField(
                controller: ttsInstructController,
                enabled: !testBusy,
                minLines: 1,
                maxLines: 2,
                onChanged: (_) {
                  setState(() {});
                  dialogRefresh?.call();
                },
                decoration: const InputDecoration(
                  labelText: 'Emotion / style (optional)',
                  hintText: 'e.g. Very happy, whispering, excited...',
                ),
              ),
            ],
          ] else ...[
            // ── Clone tab ─────────────────────────────────────────────────
            _buildCloneAudioFields(dialogRefresh),
          ],
        ] else ...[
          // Base or unknown — only clone
          _buildCloneAudioFields(dialogRefresh),
        ],

        // ── Language & Speed ────────────────────────────────────────────────
        const SizedBox(height: 20),
        const Divider(height: 1),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildStringComboBox(
                label: 'Language',
                value: ttsLanguageController.text.trim(),
                options: languageOptions,
                icon: const StudioSvgIcon('chat', size: 20),
                onChanged: (value) {
                  setState(() => ttsLanguageController.text = value ?? '');
                  dialogRefresh?.call();
                },
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 140,
              child: _buildStringComboBox(
                label: 'Speed',
                value: ttsSpeedController.text.trim(),
                options: speedOptions,
                icon: const StudioSvgIcon('play', size: 20),
                onChanged: (value) {
                  setState(() => ttsSpeedController.text = value ?? '1.0');
                  dialogRefresh?.call();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _buildLanguageQuickChoices(
          languageOptions,
          onAfterChange: dialogRefresh,
        ),
      ],
    );
  }

  Widget _buildCloneAudioFields(VoidCallback? dialogRefresh) {
    final hasMyVoice = myVoiceReferencePath != null;
    final usingMyVoice =
        hasMyVoice && ttsReferenceAudioPath == myVoiceReferencePath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // My Voice shortcut row
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: testBusy || recordingAudio
                  ? null
                  : recordingReferenceVoice
                  ? _stopReferenceVoiceRecording
                  : _startReferenceVoiceRecording,
              icon: Icon(
                recordingReferenceVoice ? Icons.stop_rounded : Icons.mic,
                size: 18,
              ),
              label: Text(recordingReferenceVoice ? 'Stop' : 'Record My Voice'),
            ),
            if (hasMyVoice) ...[
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed:
                    testBusy ||
                        recordingReferenceVoice ||
                        transcribingReferenceVoice
                    ? null
                    : () => unawaited(
                        _setTtsReferenceAudioPath(myVoiceReferencePath!),
                      ),
                icon: const Icon(Icons.person_pin_outlined, size: 18),
                label: Text(
                  usingMyVoice ? 'My Voice (active)' : 'Use My Voice',
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),
        // File picker row
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: ttsReferenceAudioPath != null
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.audiotrack_rounded,
                      size: 18,
                      color: ttsReferenceAudioPath != null
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ttsReferenceAudioPath != null
                            ? p.basename(ttsReferenceAudioPath!)
                            : 'No audio file selected',
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: ttsReferenceAudioPath != null
                              ? Theme.of(context).colorScheme.onSurface
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: testBusy ? null : _chooseTtsReferenceAudioFile,
              icon: const StudioSvgIcon('folder', size: 18),
              label: const Text('Choose'),
            ),
            if (ttsReferenceAudioPath != null) ...[
              const SizedBox(width: 6),
              IconButton(
                onPressed: testBusy
                    ? null
                    : () => setState(() {
                        ttsReferenceAudioPath = null;
                        ttsReferenceTextController.clear();
                        dialogRefresh?.call();
                      }),
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Clear',
                style: IconButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
        // Transcript field — shown only when file is set
        if (ttsReferenceAudioPath != null) ...[
          const SizedBox(height: 10),
          TextField(
            controller: ttsReferenceTextController,
            enabled: !testBusy && !transcribingReferenceVoice,
            minLines: 1,
            maxLines: 2,
            onChanged: (_) {
              setState(() {});
              dialogRefresh?.call();
            },
            decoration: InputDecoration(
              labelText: 'Reference transcript',
              hintText: transcribingReferenceVoice
                  ? 'Transcribing audio...'
                  : 'What is said in the audio clip (3–10 seconds)',
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _openTestSessionSettingsDialog(
    BuildContext context, {
    required InstalledModel? selectedModel,
    bool voicePipelineSuppressVlmInput = false,
    bool persistGenerationPrefsOnDone = false,
  }) async {
    if (selectedModel == null) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Session settings'),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Model folder',
                        style: Theme.of(dialogContext).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 6),
                      SelectableText(
                        selectedModel.directory.path,
                        style: Theme.of(dialogContext).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 18),
                      if (selectedModel.manifest.runtimeAdapter ==
                              RuntimeAdapter.mlxVlm &&
                          selectedModel.textPromptSupported &&
                          !voicePipelineSuppressVlmInput) ...[
                        Text(
                          'Input modality',
                          style: Theme.of(dialogContext).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        SegmentedButton<_TestInputMode>(
                          segments: [
                            const ButtonSegment<_TestInputMode>(
                              value: _TestInputMode.text,
                              icon: StudioSvgIcon('chat', size: 20),
                              label: Text('Text'),
                            ),
                            if (selectedModel.audioPromptSupported)
                              const ButtonSegment<_TestInputMode>(
                                value: _TestInputMode.audio,
                                icon: StudioSvgIcon('audio', size: 20),
                                label: Text('Audio'),
                              ),
                            if (selectedModel.manifest.tasks.contains(
                              ModelTask.vision,
                            ))
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
                          onSelectionChanged:
                              testBusy ||
                                  recordingAudio ||
                                  recordingReferenceVoice
                              ? null
                              : (selection) {
                                  final mode = selection.first;
                                  setState(() {
                                    audioInputMode =
                                        mode == _TestInputMode.audio;
                                    imageInputMode =
                                        mode == _TestInputMode.image;
                                    selectedAudioPath = null;
                                    selectedImagePath = null;
                                    testErrorMessage = null;
                                  });
                                  setDialogState(() {});
                                },
                        ),
                        const SizedBox(height: 18),
                      ],
                      if (voicePipelineSuppressVlmInput &&
                          selectedModel.manifest.runtimeAdapter ==
                              RuntimeAdapter.mlxVlm &&
                          selectedModel.textPromptSupported) ...[
                        Text(
                          'Voice → Voice uses the recorder in this tab for user audio. '
                          'Text / image session modes are for the Single model tab.',
                          style: Theme.of(dialogContext).textTheme.bodySmall
                              ?.copyWith(
                            color: Theme.of(dialogContext).colorScheme.outline,
                          ),
                        ),
                        const SizedBox(height: 18),
                      ],
                      if (selectedModel.textPromptSupported) ...[
                        _buildGenerationControls(selectedModel),
                        const SizedBox(height: 18),
                      ],
                      if (_modelSupportsToolCallingUi(selectedModel)) ...[
                        Text(
                          'LLM tools (JSON)',
                          style: Theme.of(dialogContext).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        _buildChatToolsJsonField(
                          selectedModel,
                          onExtraChanged: () => setDialogState(() {}),
                          minLines: 3,
                          maxLines: 8,
                        ),
                        const SizedBox(height: 18),
                      ],
                      if (selectedModel.textToSpeechSupported) ...[
                        _buildTtsVoicePanel(
                          selectedModel,
                          forDialog: true,
                          onMyVoices: () {
                            Navigator.pop(dialogContext);
                            setState(() => selectedPageIndex = 4);
                          },
                          dialogRefresh: () => setDialogState(() {}),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    if (persistGenerationPrefsOnDone) {
                      _persistGenerationPrefsForModel(selectedModel);
                    }
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('Done'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildGenerationControls(InstalledModel? model) {
    final isVlm = model?.manifest.runtimeAdapter == RuntimeAdapter.mlxVlm;
    final hint = isVlm
        ? 'mlx-vlm: max tokens + temperature (top_p skipped).'
        : _modelSupportsThinking(model)
        ? 'Qwen thinking is passed via enable_thinking in chat-template config.'
        : 'mlx-lm: max tokens, temperature, and top_p.';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Generation',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_modelSupportsThinking(model)) ...[
                  const Spacer(),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Thinking'),
                    subtitle: Text(generationThinkingEnabled ? 'On' : 'Off'),
                    value: generationThinkingEnabled,
                    onChanged: testBusy
                        ? null
                        : (value) =>
                              setState(() => generationThinkingEnabled = value),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: generationMaxTokensController,
                    enabled: !testBusy,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Max tokens',
                      prefixIcon: Padding(
                        padding: EdgeInsets.all(12),
                        child: StudioSvgIcon('chat', size: 20),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: generationTemperatureController,
                    enabled: !testBusy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Temperature',
                      prefixIcon: Padding(
                        padding: EdgeInsets.all(12),
                        child: StudioSvgIcon('sparkle', size: 20),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: generationTopPController,
                    enabled: !testBusy && !isVlm,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Top P',
                      prefixIcon: Padding(
                        padding: EdgeInsets.all(12),
                        child: StudioSvgIcon('settings', size: 20),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStringComboBox({
    required String label,
    required String value,
    required List<String> options,
    required Widget icon,
    required ValueChanged<String?> onChanged,
    bool enabled = true,
  }) {
    final normalizedOptions = _withCurrentOption(options, value);
    final selectedValue = normalizedOptions.contains(value) && value.isNotEmpty
        ? value
        : normalizedOptions.first;
    return DropdownButtonFormField<String>(
      key: ValueKey<String>('str_combo_${label}_$selectedValue'),
      initialValue: selectedValue,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Padding(padding: const EdgeInsets.all(12), child: icon),
      ),
      items: normalizedOptions
          .map(
            (item) => DropdownMenuItem<String>(
              value: item,
              child: Text(
                _prettyTtsOption(item),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(growable: false),
      onChanged: (testBusy || !enabled) ? null : onChanged,
    );
  }

  Widget _buildLanguageQuickChoices(
    List<String> languageOptions, {
    VoidCallback? onAfterChange,
  }) {
    final current = _normalizeTtsLanguageCode(ttsLanguageController.text);
    final quickOptions = <String>[
      'auto',
      'russian',
      'english',
      'chinese',
      'japanese',
      'korean',
      ...languageOptions,
    ];
    final uniqueOptions = <String>[];
    for (final option in quickOptions) {
      final normalized = _normalizeTtsLanguageCode(option);
      if (normalized.isNotEmpty && !uniqueOptions.contains(normalized)) {
        uniqueOptions.add(normalized);
      }
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: uniqueOptions
          .take(10)
          .map(
            (option) => ChoiceChip(
              label: Text(_prettyTtsOption(option)),
              selected: current == option,
              onSelected: testBusy
                  ? null
                  : (_) {
                      setState(() {
                        ttsLanguageController.text = option;
                      });
                      onAfterChange?.call();
                    },
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildSelectableError(String message) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2B2337),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF6C4F66)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Runtime error',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: message));
                  if (!mounted) {
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied error text')),
                  );
                },
                icon: const StudioSvgIcon('copy', size: 18),
                label: const Text('Copy'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText(
                  message,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<String> _ttsVoiceOptions(ModelRuntimeConfig? config) {
    if (config == null) {
      return const <String>[];
    }
    final schemaOptions = _schemaEnumValues(config, 'voice');
    if (schemaOptions.isNotEmpty) {
      return schemaOptions;
    }
    return config.voices
        .map((voice) => voice.id)
        .where((id) => id.trim().isNotEmpty && id != 'default')
        .toList(growable: false);
  }

  /// The compact speaker strip may show [voicePickOptions.first] while
  /// [ttsVoiceController] is still empty — always align synthesis with a real
  /// catalog preset when one exists.
  String _effectiveTtsVoiceForModel(InstalledModel model) {
    final presets = _ttsVoiceOptions(model.manifest.runtimeConfig);
    final picked = ttsVoiceController.text.trim();
    if (presets.isEmpty) {
      return picked;
    }
    if (picked.isNotEmpty && presets.contains(picked)) {
      return picked;
    }
    return presets.first;
  }

  List<String> _ttsLanguageOptions(ModelRuntimeConfig? config) {
    final options = config == null
        ? const <String>[]
        : _schemaEnumValues(config, 'lang_code');
    return options.isEmpty
        ? const <String>[
            'auto',
            'russian',
            'english',
            'chinese',
            'japanese',
            'korean',
            'german',
            'french',
            'portuguese',
            'spanish',
            'italian',
          ]
        : options;
  }

  List<String> _schemaEnumValues(ModelRuntimeConfig config, String property) {
    final properties = config.parameterSchema['properties'];
    if (properties is! Map) {
      return const <String>[];
    }
    final propertySchema = properties[property];
    if (propertySchema is! Map) {
      return const <String>[];
    }
    final enumValues = propertySchema['enum'];
    if (enumValues is! List) {
      return const <String>[];
    }
    return enumValues.map((value) => '$value').toList(growable: false);
  }

  List<String> _withCurrentOption(List<String> options, String current) {
    final values = <String>[
      ...options.where((option) => option.trim().isNotEmpty),
    ];
    if (current.trim().isNotEmpty && !values.contains(current.trim())) {
      values.insert(0, current.trim());
    }
    return values.isEmpty ? const <String>['auto'] : values;
  }

  String _prettyTtsOption(String value) {
    final normalized = _normalizeTtsLanguageCode(value);
    if (normalized.length <= 1) {
      return normalized;
    }
    return normalized
        .split('_')
        .map(
          (part) => part.isEmpty
              ? part
              : '${part[0].toUpperCase()}${part.substring(1)}',
        )
        .join(' ');
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
              onPressed: testBusy || recordingReferenceVoice
                  ? null
                  : recordingAudio
                  ? _stopAudioRecording
                  : _startAudioRecording,
              icon: StudioSvgIcon(recordingAudio ? 'stop' : 'mic', size: 20),
              label: Text(recordingAudio ? 'Stop' : 'Record'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: recordingAudio || recordingReferenceVoice || testBusy
                  ? null
                  : _chooseAudioFile,
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
                  onPressed: () => setState(() => selectedPageIndex = 5),
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
            if (!model.manifest.runtimeConfig.isEmpty)
              Text(_runtimeConfigSummary(model.manifest.runtimeConfig)),
            if (model.metadataUpdatedAt != null)
              Text(
                'Config updated: ${_formatDateTime(model.metadataUpdatedAt!)}',
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
                  onPressed: () =>
                      _runAction(() => _refreshInstalledModelMetadata(model)),
                  icon: const StudioSvgIcon('refresh', size: 20),
                  label: const Text('Update Config'),
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
      if (model.textPromptSupported) {
        _applyGenerationDefaultsForModel(model);
      }
      if (model.textToSpeechSupported) {
        _applyTtsDefaultsForModel(model);
      }
    });
    controller.clearChat();
  }

  Future<void> _openVoicePipelineSettingsDialog(
    BuildContext context, {
    required InstalledModel? ttsModel,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('TTS & remote streaming'),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (ttsModel != null) ...[
                        _buildTtsVoicePanel(
                          ttsModel,
                          forDialog: true,
                          onMyVoices: () {
                            Navigator.pop(dialogContext);
                            setState(() => selectedPageIndex = 4);
                          },
                          dialogRefresh: () => setDialogState(() {}),
                        ),
                        const SizedBox(height: 16),
                      ],
                      const Divider(),
                      SwitchListTile(
                        title: const Text('Stream TTS (OpenAI-compatible)'),
                        subtitle: const Text(
                          'Server must implement POST /v1/audio/speech with stream: true.',
                        ),
                        value: streamSpeechEnabled,
                        onChanged: testBusy
                            ? null
                            : (value) {
                                setState(() => streamSpeechEnabled = value);
                                setDialogState(() {});
                              },
                      ),
                      TextField(
                        controller: streamingTtsEndpointController,
                        enabled: !testBusy,
                        decoration: const InputDecoration(
                          labelText: 'Speech URL',
                          hintText: 'http://127.0.0.1:8000/v1/audio/speech',
                        ),
                        onChanged: (_) => setDialogState(() {}),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: streamingTtsModelIdController,
                        enabled: !testBusy,
                        decoration: const InputDecoration(
                          labelText: 'Remote speech model id (optional)',
                          hintText: 'Overrides manifest id in the JSON body',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    _persistVoicePipelinePrefs(
                      chatModel: null,
                      ttsModel: ttsModel,
                    );
                  },
                  child: const Text('Done'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _applyStoredPrefsForChatModel(InstalledModel? model) {
    if (model == null) {
      return;
    }
    final prefs = _prefsStore.prefsForModel(model.manifest.id);
    if (prefs == null) {
      return;
    }
    final gen = prefs['generation'];
    if (gen is! Map) {
      return;
    }
    final maxTokens = gen['maxTokens'];
    final temperature = gen['temperature'];
    final topP = gen['topP'];
    final thinking = gen['thinking'];
    if (maxTokens != null) {
      generationMaxTokensController.text = '$maxTokens';
    }
    if (temperature != null) {
      generationTemperatureController.text = '$temperature';
    }
    if (topP != null) {
      generationTopPController.text = '$topP';
    }
    if (thinking is bool) {
      generationThinkingEnabled = thinking;
    }
  }

  void _applyStoredPrefsForTtsModel(InstalledModel? model) {
    if (model == null) {
      return;
    }
    final prefs = _prefsStore.prefsForModel(model.manifest.id);
    if (prefs == null) {
      return;
    }
    final tts = prefs['tts'];
    if (tts is Map) {
      final voice = tts['voice'] as String?;
      final instruct = tts['instruct'] as String?;
      final lang = tts['lang'] as String?;
      final speed = tts['speed'] as String?;
      if (voice != null && voice.isNotEmpty) {
        ttsVoiceController.text = voice;
      }
      if (instruct != null) {
        ttsInstructController.text = instruct;
      }
      if (lang != null && lang.isNotEmpty) {
        ttsLanguageController.text = lang;
      }
      if (speed != null && speed.isNotEmpty) {
        ttsSpeedController.text = speed;
      }
    }
    final stream = prefs['streamingSpeech'];
    if (stream is bool) {
      streamSpeechEnabled = stream;
    }
    final endpoint = prefs['streamingSpeechEndpoint'] as String?;
    if (endpoint != null && endpoint.isNotEmpty) {
      streamingTtsEndpointController.text = endpoint;
    }
    final speechModel = prefs['streamingSpeechModel'] as String?;
    if (speechModel != null && speechModel.isNotEmpty) {
      streamingTtsModelIdController.text = speechModel;
    }
  }

  void _persistGenerationPrefsForModel(InstalledModel model) {
    unawaited(
      _prefsStore.mergeModelPrefs(model.manifest.id, {
        'generation': <String, Object?>{
          'maxTokens': int.tryParse(
            generationMaxTokensController.text.trim(),
          ),
          'temperature': double.tryParse(
            generationTemperatureController.text.trim(),
          ),
          'topP': double.tryParse(generationTopPController.text.trim()),
          'thinking': generationThinkingEnabled,
        },
      }),
    );
  }

  void _persistVoicePipelinePrefs({
    InstalledModel? chatModel,
    InstalledModel? ttsModel,
  }) {
    if (chatModel != null) {
      _persistGenerationPrefsForModel(chatModel);
    }
    if (ttsModel != null) {
      unawaited(
        _prefsStore.mergeModelPrefs(ttsModel.manifest.id, {
          'tts': <String, Object?>{
            'voice': ttsVoiceController.text.trim(),
            'instruct': ttsInstructController.text.trim(),
            'lang': ttsLanguageController.text.trim(),
            'speed': ttsSpeedController.text.trim(),
          },
          'streamingSpeech': streamSpeechEnabled,
          'streamingSpeechEndpoint': streamingTtsEndpointController.text.trim(),
          'streamingSpeechModel': streamingTtsModelIdController.text.trim(),
        }),
      );
    }
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
    ttsVoiceController.text = voice?.trim() ?? '';
    final presetNames = _ttsVoiceOptions(model.manifest.runtimeConfig);
    if (presetNames.isNotEmpty && ttsVoiceController.text.trim().isEmpty) {
      ttsVoiceController.text = presetNames.first;
    }
    ttsInstructController.clear();
    if (ttsReferenceAudioPath == null) {
      ttsReferenceTextController.clear();
    } else {
      unawaited(_loadOrTranscribeReferenceTranscript(ttsReferenceAudioPath!));
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

  void _applyGenerationDefaultsForModel(InstalledModel? model) {
    if (model == null) {
      return;
    }
    final defaults = model.manifest.runtimeConfig.defaultParameters;
    generationMaxTokensController.text =
        '${defaults['max_tokens'] ?? defaults['maxTokens'] ?? 256}';
    final temperature = defaults['temperature'] ?? defaults['temp'];
    generationTemperatureController.text = '${temperature ?? 0.7}';
    final topP = defaults['top_p'] ?? defaults['topP'];
    generationTopPController.text = '${topP ?? 0.95}';
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
    await _setTtsReferenceAudioPath(file.path);
  }

  Future<void> _importVoiceReferenceAudioFile() async {
    final file = await _openAudioFile();
    if (file == null) {
      return;
    }
    final directory = controller.paths.voiceReferencesDirectory;
    await directory.create(recursive: true);
    final extension = p.extension(file.path).isEmpty
        ? '.m4a'
        : p.extension(file.path);
    final destination = File(
      p.join(
        directory.path,
        'my-voice-${DateTime.now().millisecondsSinceEpoch}$extension',
      ),
    );
    await File(file.path).copy(destination.path);
    setState(() {
      myVoiceReferencePath = destination.path;
      testErrorMessage = null;
    });
    await _setTtsReferenceAudioPath(destination.path);
  }

  Future<void> _startReferenceVoiceRecording() async {
    final hasPermission = await audioRecorder.hasPermission();
    if (!hasPermission) {
      setState(() => testErrorMessage = 'Microphone permission was denied.');
      return;
    }

    final directory = controller.paths.voiceReferencesDirectory;
    await directory.create(recursive: true);
    final path = p.join(
      directory.path,
      'my-voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
    );
    await audioRecorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );
    setState(() {
      recordingReferenceVoice = true;
      testErrorMessage = null;
    });
  }

  Future<void> _stopReferenceVoiceRecording() async {
    String? path;
    try {
      path = await audioRecorder.stop();
    } finally {
      if (mounted) {
        setState(() => recordingReferenceVoice = false);
      }
    }
    if (!mounted) {
      return;
    }
    if (path == null) {
      return;
    }
    final duration = await _probeAudioDuration(path);
    if (duration != null && duration < const Duration(seconds: 2)) {
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
      }
      final fallback = _bestVoiceReferenceFile();
      if (!mounted) {
        return;
      }
      setState(() {
        myVoiceReferencePath = fallback?.path;
        ttsReferenceAudioPath = fallback?.path;
        if (fallback == null) {
          ttsReferenceTextController.clear();
        }
        testErrorMessage =
            'Voice sample is too short (${_formatDuration(duration)}). Record a clean 3–10 sec sample.';
      });
      if (fallback != null) {
        await _setTtsReferenceAudioPath(fallback.path);
      }
      return;
    }
    await _selectVoiceReference(path);
  }

  Future<void> _selectVoiceReference(
    String path, {
    bool openTest = false,
  }) async {
    if (!File(path).existsSync()) {
      if (!mounted) {
        return;
      }
      setState(
        () => testErrorMessage = 'Voice reference file no longer exists: $path',
      );
      return;
    }
    final duration = await _probeAudioDuration(path);
    if (duration != null && duration < const Duration(seconds: 2)) {
      if (!mounted) {
        return;
      }
      setState(
        () => testErrorMessage =
            'Voice sample is too short (${_formatDuration(duration)}). Record a clean 3–10 sec sample.',
      );
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      myVoiceReferencePath = path;
      if (openTest) {
        selectedPageIndex = 2;
      }
    });
    await _setTtsReferenceAudioPath(path);
  }

  Future<void> _setTtsReferenceAudioPath(String path) async {
    final changed = ttsReferenceAudioPath != path;
    if (!mounted) {
      return;
    }
    setState(() {
      ttsReferenceAudioPath = path;
      _ttsCloneMode = true;
      testErrorMessage = null;
      if (changed) {
        ttsReferenceTextController.clear();
      }
    });
    try {
      await _loadOrTranscribeReferenceTranscript(path);
    } catch (error) {
      if (!mounted || ttsReferenceAudioPath != path) {
        return;
      }
      setState(
        () => testErrorMessage =
            'Could not select the reference voice. Try importing the audio again.\n$error',
      );
    }
  }

  Future<void> _loadOrTranscribeReferenceTranscript(String audioPath) async {
    try {
      final sidecar = File(p.setExtension(audioPath, '.txt'));
      if (await sidecar.exists()) {
        final cachedTranscript = (await sidecar.readAsString()).trim();
        if (cachedTranscript.isNotEmpty && mounted) {
          setState(() => ttsReferenceTextController.text = cachedTranscript);
          return;
        }
        await sidecar.delete();
      }
      if (ttsReferenceTextController.text.trim().isNotEmpty) {
        return;
      }
      final asrModel = _referenceTranscriptModel();
      if (asrModel == null || !mounted) {
        return;
      }
      setState(() => transcribingReferenceVoice = true);
      final transcript = await controller.transcribeAudio(
        model: asrModel,
        audioPath: audioPath,
      );
      await sidecar.writeAsString(transcript);
      if (!mounted || ttsReferenceAudioPath != audioPath) {
        return;
      }
      setState(() => ttsReferenceTextController.text = transcript);
    } catch (error) {
      if (!mounted || ttsReferenceAudioPath != audioPath) {
        return;
      }
      setState(
        () => testErrorMessage =
            'Could not auto-transcribe the reference voice. Paste the exact Reference transcript manually.\n$error',
      );
    } finally {
      if (mounted) {
        setState(() => transcribingReferenceVoice = false);
      }
    }
  }

  InstalledModel? _referenceTranscriptModel() {
    for (final model in controller.installedModels) {
      if (model.speechToTextSupported) {
        return model;
      }
    }
    return null;
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

  Future<void> _stopAudioRecording({bool runVoicePipelineOnStop = true}) async {
    String? path;
    try {
      path = await audioRecorder.stop();
    } finally {
      if (mounted) {
        setState(() {
          recordingAudio = false;
          if (path != null) {
            selectedAudioPath = path;
          }
        });
      }
    }
    if (path != null &&
        runVoicePipelineOnStop &&
        testWorkspaceMode == _TestWorkspaceMode.voicePipeline) {
      _runVoicePipelineWithCurrentSelection();
    }
  }

  void _runVoicePipelineWithCurrentSelection() {
    if (testBusy ||
        recordingAudio ||
        recordingReferenceVoice ||
        selectedAudioPath == null) {
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

  bool _isE2eBenchmarkModel(InstalledModel model) {
    return model.textPromptSupported || model.textToSpeechSupported;
  }

  Future<void> _runE2eBenchmark(List<InstalledModel> candidates) async {
    if (testBusy) {
      return;
    }
    setState(() {
      testBusy = true;
      testErrorMessage = null;
      e2eBenchmarkResults.clear();
    });

    try {
      for (final model in candidates) {
        if (!mounted) {
          return;
        }
        if (model.textPromptSupported) {
          await _runE2eChatBenchmark(model);
        }
        if (!mounted) {
          return;
        }
        if (model.textToSpeechSupported) {
          await _runE2eSpeechBenchmark(model);
        }
      }
    } finally {
      if (mounted) {
        setState(() => testBusy = false);
      }
    }
  }

  Future<void> _runE2eChatBenchmark(InstalledModel model) async {
    final result = _E2eBenchmarkResult(
      modelName: model.manifest.displayName,
      task: 'chat',
    );
    setState(() => e2eBenchmarkResults.add(result));
    try {
      final cold = await _benchmarkChatPrompt(
        model,
        'Reply with exactly one short English sentence: what is this app testing?',
      );
      result.coldStartDuration = cold.duration;
      result.output = 'Cold output: ${cold.output}';
      if (mounted) {
        setState(() {});
      }

      final second = await _benchmarkChatPrompt(
        model,
        'Now reply with exactly one short Russian sentence about local AI.',
      );
      result.secondRunDuration = second.duration;
      result.output =
          'Cold output: ${cold.output}\nSecond output: ${second.output}';
      result.status = _E2eBenchmarkStatus.passed;
    } catch (error) {
      result.status = _E2eBenchmarkStatus.failed;
      result.error = '$error';
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _runE2eSpeechBenchmark(InstalledModel model) async {
    final result = _E2eBenchmarkResult(
      modelName: model.manifest.displayName,
      task: 'text-to-speech',
    );
    setState(() => e2eBenchmarkResults.add(result));
    final skipReason = _ttsBenchmarkSkipReason(model);
    if (skipReason != null) {
      result.status = _E2eBenchmarkStatus.skipped;
      result.output = skipReason;
      setState(() {});
      return;
    }

    try {
      final cold = await _benchmarkSpeechPrompt(
        model,
        'Hello. This is a local text to speech cold start benchmark.',
      );
      result.coldStartDuration = cold.duration;
      result.output = 'Cold audio: ${cold.output}';
      if (mounted) {
        setState(() {});
      }

      final second = await _benchmarkSpeechPrompt(
        model,
        'Second synthesis run for warm timing.',
      );
      result.secondRunDuration = second.duration;
      result.output =
          'Cold audio: ${cold.output}\nSecond audio: ${second.output}';
      result.status = _E2eBenchmarkStatus.passed;
    } catch (error) {
      result.status = _E2eBenchmarkStatus.failed;
      result.error = '$error';
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<_BenchmarkRunOutput> _benchmarkChatPrompt(
    InstalledModel model,
    String prompt,
  ) async {
    final stopwatch = Stopwatch()..start();
    final response = await controller.chatRunner.chatStream(
      model: model,
      messages: [LocalChatMessage.user(prompt)],
      params: _benchmarkChatParamsForModel(model),
      onText: (_) {},
    );
    stopwatch.stop();
    return _BenchmarkRunOutput(
      duration: stopwatch.elapsed,
      output: response.trim().isEmpty ? '<empty response>' : response.trim(),
    );
  }

  Future<_BenchmarkRunOutput> _benchmarkSpeechPrompt(
    InstalledModel model,
    String text,
  ) async {
    final stopwatch = Stopwatch()..start();
    final file = await controller.synthesizeSpeech(
      model: model,
      text: text,
      options: _speechOptionsForBenchmarkModel(model),
    );
    stopwatch.stop();
    final duration = await _probeAudioDuration(file.path);
    final size = await file.length();
    return _BenchmarkRunOutput(
      duration: stopwatch.elapsed,
      output: [
        p.basename(file.path),
        formatBytes(size),
        if (duration != null) 'audio ${_formatDuration(duration)}',
      ].join(' • '),
    );
  }

  LocalChatParams _benchmarkChatParamsForModel(InstalledModel model) {
    final defaults = model.manifest.runtimeConfig.defaultParameters;
    return LocalChatParams(
      modelId: model.manifest.id,
      maxTokens: _intDefault(defaults, const [
        'max_tokens',
        'maxTokens',
        'max_new_tokens',
      ], fallback: 128),
      temperature: _doubleDefault(defaults, const [
        'temperature',
        'temp',
      ], fallback: 0.4),
      topP: model.manifest.runtimeAdapter == RuntimeAdapter.mlxVlm
          ? null
          : _doubleDefault(defaults, const ['top_p', 'topP'], fallback: 0.9),
      enableThinking: _modelSupportsThinking(model) ? false : null,
    );
  }

  SpeechSynthesisOptions _speechOptionsForBenchmarkModel(InstalledModel model) {
    final config = model.manifest.runtimeConfig;
    final defaults = config.defaultParameters;
    final mode = config.extra['qwen_tts_mode'] as String? ?? '';
    var voice = '${defaults['voice'] ?? ''}'.trim();
    if (voice.isEmpty && mode != 'base' && config.voices.isNotEmpty) {
      voice = config.voices.first.id;
    }
    final instruct = '${defaults['instruct'] ?? defaults['voice_prompt'] ?? ''}'
        .trim();
    final language = '${defaults['lang_code'] ?? defaults['language'] ?? ''}'
        .trim();
    return SpeechSynthesisOptions(
      voice: voice,
      instruct: instruct,
      languageCode: language.isEmpty ? '' : _normalizeTtsLanguageCode(language),
      referenceAudioPath: ttsReferenceAudioPath,
      referenceText: ttsReferenceTextController.text.trim(),
      speed: _doubleValue(defaults['speed']),
    );
  }

  String? _ttsBenchmarkSkipReason(InstalledModel model) {
    if (!_supportsReferenceVoiceClone(model)) {
      return null;
    }
    final presetSpeakers = _ttsVoiceOptions(model.manifest.runtimeConfig);
    final defaults = model.manifest.runtimeConfig.defaultParameters;
    final voiceFromDefaults = '${defaults['voice'] ?? ''}'.trim();
    if (presetSpeakers.isNotEmpty &&
        voiceFromDefaults.isNotEmpty &&
        presetSpeakers.contains(voiceFromDefaults)) {
      return null;
    }
    final hasReferenceAudio =
        ttsReferenceAudioPath != null &&
        ttsReferenceAudioPath!.trim().isNotEmpty;
    final hasReferenceText = ttsReferenceTextController.text.trim().isNotEmpty;
    if (!hasReferenceAudio || !hasReferenceText) {
      return 'Skipped: voice cloning needs Ref Audio + Reference transcript. Open Voices, record/import a clean 3–10 sec sample, then rerun E2E.';
    }
    return null;
  }

  int _intDefault(
    Map<String, Object?> defaults,
    List<String> keys, {
    required int fallback,
  }) {
    for (final key in keys) {
      final value = defaults[key];
      if (value is int) {
        return value;
      }
      if (value is num) {
        return value.toInt();
      }
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return fallback;
  }

  double? _doubleDefault(
    Map<String, Object?> defaults,
    List<String> keys, {
    double? fallback,
  }) {
    for (final key in keys) {
      final parsed = _doubleValue(defaults[key]);
      if (parsed != null) {
        return parsed;
      }
    }
    return fallback;
  }

  double? _doubleValue(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value.trim());
    }
    return null;
  }

  Future<void> _sendPromptToSelectedModel(InstalledModel model) async {
    final prompt = chatPromptController.text.trim();
    if (prompt.isEmpty) {
      return;
    }
    final toolsErr = _chatToolsFieldError(model);
    if (toolsErr != null) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(toolsErr),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
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

    final stopwatch = Stopwatch()..start();
    try {
      final response = await controller.chatRunner.chatStream(
        model: model,
        messages: messages,
        params: _chatParamsForModel(model),
        toolRegistry: _chatToolRegistryForSend(model),
        onText: _replaceStreamingAssistant,
      );
      stopwatch.stop();
      _replaceStreamingAssistant(
        response,
        generationDuration: stopwatch.elapsed,
      );
    } catch (error) {
      setState(() => testErrorMessage = '$error');
    } finally {
      setState(() => testBusy = false);
      _scrollChatToBottom();
    }
  }

  InstalledModel? _firstAsrModel() {
    for (final m in controller.installedModels) {
      if (m.speechToTextSupported) {
        return m;
      }
    }
    return null;
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
    final toolsErr = _chatToolsFieldError(model);
    if (toolsErr != null) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(toolsErr),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    final userMessage = prompt.isEmpty
        ? 'Audio: ${p.basename(audioPath)}'
        : 'Audio: ${p.basename(audioPath)}\n$prompt';

    setState(() {
      testBusy = true;
      testErrorMessage = null;
      controller.chatTurns.add(ChatTurn.user(userMessage));
    });
    _scrollChatToBottom();

    final stopwatch = Stopwatch()..start();
    try {
      if (model.dedicatedSpeechToTextModel) {
        // Dedicated mlx_audio ASR — transcribe only (not Gemma4 chat which also advertises STT).
        final response = await controller.transcribeAudio(
          model: model,
          audioPath: audioPath,
        );
        stopwatch.stop();
        setState(
          () => controller.chatTurns.add(
            ChatTurn.assistant(response, generationDuration: stopwatch.elapsed),
          ),
        );
      } else {
        // LM/VLM model with audioPromptSupported.
        // The native Swift bridge does not yet support audio-conditioned LM
        // inference. Work around by transcribing the audio first (using any
        // installed ASR model) and injecting the transcript into the prompt.
        final asrModel = _firstAsrModel();
        String? transcript;
        if (asrModel != null) {
          setState(
            () => controller.chatTurns.add(
              const ChatTurn.assistant('Transcribing audio…'),
            ),
          );
          _scrollChatToBottom();
          try {
            transcript = await controller.transcribeAudio(
              model: asrModel,
              audioPath: audioPath,
            );
          } catch (_) {
            transcript = null;
          }
          // Remove the temporary transcription indicator.
          setState(() {
            if (controller.chatTurns.isNotEmpty &&
                controller.chatTurns.last.message == 'Transcribing audio…') {
              controller.chatTurns.removeLast();
            }
          });
        }

        if (transcript == null || transcript.trim().isEmpty) {
          // No ASR model installed or transcription failed — inform the user.
          stopwatch.stop();
          setState(
            () => controller.chatTurns.add(
              ChatTurn.assistant(
                asrModel == null
                    ? 'Audio input for chat models requires a speech-to-text '
                          'model to be installed. Install a Whisper or VibeVoice '
                          'ASR model and try again.\n\n'
                          'Audio file: ${p.basename(audioPath)}'
                    : 'Audio transcription failed. Please try again.',
                generationDuration: stopwatch.elapsed,
              ),
            ),
          );
          return;
        }

        // Build a prompt that includes the transcript and user text.
        final transcriptLabel =
            '📢 Audio transcript (${p.basename(audioPath)}):';
        final fullPrompt = prompt.isEmpty
            ? '$transcriptLabel\n$transcript'
            : '$transcriptLabel\n$transcript\n\n$prompt';

        final messages = _messagesForCurrentChat(
          LocalChatMessage.user(fullPrompt),
        );

        setState(() => controller.chatTurns.add(const ChatTurn.assistant('')));
        _scrollChatToBottom();

        final response = await controller.chatRunner.chatStream(
          model: model,
          messages: messages,
          params: _chatParamsForModel(model),
          toolRegistry: _chatToolRegistryForSend(model),
          onText: _replaceStreamingAssistant,
        );
        stopwatch.stop();
        _replaceStreamingAssistant(
          response,
          generationDuration: stopwatch.elapsed,
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
    final toolsErr = _chatToolsFieldError(model);
    if (toolsErr != null) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(toolsErr),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
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

    final stopwatch = Stopwatch()..start();
    try {
      final response = await controller.chatRunner.chatStream(
        model: model,
        messages: messages,
        params: _chatParamsForModel(model),
        toolRegistry: _chatToolRegistryForSend(model),
        onText: _replaceStreamingAssistant,
      );
      stopwatch.stop();
      _replaceStreamingAssistant(
        response,
        generationDuration: stopwatch.elapsed,
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
      controller.chatTurns.add(
        const ChatTurn.assistant('Generating image... 0%', progress: 0),
      );
    });
    _scrollChatToBottom();

    final stopwatch = Stopwatch()..start();
    try {
      final imageFile = await controller.generateImage(
        model: model,
        prompt: prompt,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          final safeProgress = progress.clamp(0.0, 1.0).toDouble();
          final percent = (safeProgress * 100).round();
          setState(() {
            final lastIndex = controller.chatTurns.lastIndexWhere(
              (turn) => !turn.isUser,
            );
            final progressTurn = ChatTurn.assistant(
              'Generating image... $percent%',
              progress: safeProgress,
            );
            if (lastIndex == -1) {
              controller.chatTurns.add(progressTurn);
            } else {
              controller.chatTurns[lastIndex] = progressTurn;
            }
          });
          _scrollChatToBottom();
        },
      );
      stopwatch.stop();
      setState(() {
        final lastIndex = controller.chatTurns.lastIndexWhere(
          (turn) => !turn.isUser,
        );
        final generatedTurn = ChatTurn.assistant(
          'Generated image',
          imagePath: imageFile.path,
          generationDuration: stopwatch.elapsed,
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
    });
    final validationError = await _prepareSpeechOptionsForModel(model);
    if (validationError != null) {
      setState(() {
        testBusy = false;
        testErrorMessage = validationError;
      });
      return;
    }
    setState(() {
      controller.chatTurns.add(ChatTurn.user(text));
      controller.chatTurns.add(
        const ChatTurn.assistant('Generating local speech...'),
      );
    });
    _scrollChatToBottom();

    final stopwatch = Stopwatch()..start();
    try {
      final file = await controller.synthesizeSpeech(
        model: model,
        text: text,
        options: _speechOptionsFromUi(ttsModel: model),
      );
      stopwatch.stop();
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
            generationDuration: stopwatch.elapsed,
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

  Future<String?> _writeVoicePipelineTtsSegment(
    sdk.VoiceAudioChunk chunk,
    int index,
  ) async {
    if (chunk.bytes.isEmpty) {
      return null;
    }
    final ext = switch (chunk.mediaType) {
      'audio/opus' => 'opus',
      'audio/mpeg' => 'mp3',
      _ => 'wav',
    };
    final dir = await Directory.systemTemp.createTemp('flm-v2v-seg-');
    final path = p.join(
      dir.path,
      'seg_${index.toString().padLeft(4, '0')}.$ext',
    );
    await File(path).writeAsBytes(chunk.bytes);
    return path;
  }

  Future<void> _playVoicePipelineSegmentsSequentially(
    List<String> paths,
  ) async {
    for (final path in paths) {
      if (!mounted) {
        return;
      }
      if (!File(path).existsSync()) {
        continue;
      }
      try {
        await audioPlayer.stop();
        await audioPlayer.play(DeviceFileSource(path));
        if (mounted) {
          setState(() => playingAudioPath = path);
        }
        await audioPlayer.onPlayerComplete.first;
      } catch (_) {
        break;
      }
    }
    if (mounted) {
      setState(() => playingAudioPath = null);
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
    });
    final voiceCubit = _voicePipelineCubit;
    voiceCubit.setTranscribing();
    final validationError = await _prepareSpeechOptionsForModel(ttsModel);
    if (validationError != null) {
      voiceCubit.reset();
      setState(() {
        testBusy = false;
        testErrorMessage = validationError;
      });
      return;
    }
    final toolsErr = _chatToolsFieldError(chatModel);
    if (toolsErr != null) {
      voiceCubit.reset();
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(toolsErr),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      setState(() {
        testBusy = false;
      });
      return;
    }
    setState(() {
      controller.chatTurns.add(
        ChatTurn.user('Audio: ${p.basename(audioPath)}'),
      );
      controller.chatTurns.add(const ChatTurn.assistant('Transcribing...'));
    });
    _scrollChatToBottom();

    final stopwatch = Stopwatch()..start();
    var voicePipelineUserCancelled = false;
    try {
      _voicePipelineCancel = sdk.Voice2VoiceCancelToken();
      final instruction = chatPromptController.text.trim();
      final chatParams = _chatParamsForModel(chatModel);
      final speechOpts = _speechOptionsFromUi(ttsModel: ttsModel);
      final ttsCoalescing = _voicePipelineTtsCoalescing(ttsModel);
      _voiceUxLog(
        'Full generation trace: filter console by [VoiceUX:chain] (pipeline steps, '
        'speaker on each TTS segment). Also: [VoiceUX], [TTS], native_mlx_*.',
      );
      _voiceUxLog(
        'Pipeline start: same audio file is run again through ASR → chat → TTS; '
        'LLM output and speech are recomputed from scratch.',
      );
      _voiceUxLog(
        'audio=${p.basename(audioPath)} instruction=${_voiceUxPreview(instruction, 120)}',
      );
      _voiceUxLog(
        'models asr=${asrModel.manifest.id} chat=${chatModel.manifest.id} tts=${ttsModel.manifest.id}',
      );
      _voiceUxLog(
        'chat sampling temp=${chatParams.temperature} topP=${chatParams.topP} maxTokens=${chatParams.maxTokens}',
      );
      _voiceUxLog('TTS coalescing: ${_voiceUxTtsCoalescingLabel(ttsCoalescing)}');
      _voiceUxLog(
        'TTS UI: voiceRaw="${ttsVoiceController.text.trim()}" voiceResolved="${speechOpts.voice}" '
        'voiceDesignPreset=$_ttsVoiceDesignUsesPreset cloneMode=$_ttsCloneMode '
        'instruct=${_voiceUxPreview(speechOpts.instruct, 80)} lang=${speechOpts.languageCode} '
        'speed=${speechOpts.speed} streamRemote=${speechOpts.streamSpeech}',
      );
      final pipeline = sdk.StreamingVoice2VoicePipeline(
        asrEngine: StudioFileStreamingAsrEngine(
          audioRunner: controller.audioRunner,
          audioFilePath: audioPath,
        ),
        chatRunner: StudioStreamingChatRunnerAdapter(controller.chatRunner),
        ttsEngine: StudioLocalStreamingTtsEngine(
          controller.audioRunner,
          speechOpts,
        ),
      );

      final assistantAccum = StringBuffer();
      var assistantFinal = '';
      final segmentPaths = <String>[];
      var segmentIndex = 0;
      var ttsStarted = false;

      await for (final event in pipeline.run(
        asrModel: installedModelToSdk(asrModel),
        chatModel: installedModelToSdk(chatModel),
        ttsModel: installedModelToSdk(ttsModel),
        userAudio: voiceFileChunkStream(audioPath),
        instruction: instruction,
        chatParams: chatParams,
        chatToolRegistry: _chatToolRegistryForSend(chatModel),
        ttsOptions: sdk.VoiceSynthesisOptions(
          voice: speechOpts.voice,
          languageCode: speechOpts.languageCode.isEmpty
              ? 'auto'
              : speechOpts.languageCode,
          speed: speechOpts.speed,
          referenceAudioPath: speechOpts.referenceAudioPath,
          referenceText: speechOpts.referenceText.isEmpty
              ? null
              : speechOpts.referenceText,
          instruct:
              speechOpts.instruct.isEmpty ? null : speechOpts.instruct,
        ),
        ttsCoalescing: ttsCoalescing,
        cancelToken: _voicePipelineCancel,
      )) {
        if (!mounted) {
          break;
        }
        switch (event.type) {
          case sdk.Voice2VoiceEventType.asrPartial:
            break;
          case sdk.Voice2VoiceEventType.asrFinal:
            voiceCubit.setReplying();
            setState(() {
              if (controller.chatTurns.isNotEmpty &&
                  !controller.chatTurns.last.isUser) {
                controller.chatTurns[controller.chatTurns.length - 1] =
                    ChatTurn.assistant('Transcript: ${event.text}');
              }
              controller.chatTurns.add(ChatTurn.user(event.text!));
              controller.chatTurns.add(const ChatTurn.assistant(''));
            });
            _scrollChatToBottom();
          case sdk.Voice2VoiceEventType.assistantDelta:
            assistantAccum.write(event.text);
            _replaceStreamingAssistant(assistantAccum.toString());
          case sdk.Voice2VoiceEventType.assistantFinal:
            assistantFinal = event.text!;
            _replaceStreamingAssistant(assistantFinal);
            _voiceUxLog(
              'assistantFinal chars=${assistantFinal.length} '
              'preview=${_voiceUxPreview(assistantFinal, 100)}',
            );
          case sdk.Voice2VoiceEventType.ttsAudio:
            final audio = event.audio!;
            if (!audio.isFinal && audio.bytes.isNotEmpty) {
              if (!ttsStarted) {
                ttsStarted = true;
                voiceCubit.setSynthesizing();
              }
              final idx = segmentIndex++;
              final path = await _writeVoicePipelineTtsSegment(
                audio,
                idx,
              );
              if (path != null) {
                segmentPaths.add(path);
                _voiceUxLog(
                  'TTS segment file: idx=$idx bytes=${audio.bytes.length} '
                  '${p.basename(path)}',
                );
              }
            }
          case sdk.Voice2VoiceEventType.cancelled:
            voicePipelineUserCancelled = true;
            try {
              await audioPlayer.stop();
            } catch (_) {}
            voiceCubit.reset();
            break;
          case sdk.Voice2VoiceEventType.done:
            break;
        }
      }
      stopwatch.stop();

      if (voicePipelineUserCancelled) {
        _voiceUxLog(
          'Pipeline stopped by user after ${stopwatch.elapsed.inMilliseconds}ms',
        );
        return;
      }

      _voiceUxLog(
        'Pipeline finished: segments=${segmentPaths.length} elapsed=${stopwatch.elapsed.inMilliseconds}ms',
      );

      final speechPath =
          segmentPaths.isNotEmpty ? segmentPaths.last : null;

      final duration = speechPath != null
          ? await _probeAudioDuration(speechPath)
          : null;
      setState(() {
        generatedAudioPath = speechPath;
        if (controller.chatTurns.isNotEmpty &&
            !controller.chatTurns.last.isUser) {
          controller.chatTurns[controller.chatTurns.length - 1] =
              ChatTurn.assistant(
                assistantFinal,
                audioPath: speechPath,
                duration: duration,
                generationDuration: stopwatch.elapsed,
              );
        }
      });
      voiceCubit.reset();
      if (segmentPaths.isNotEmpty) {
        await _playVoicePipelineSegmentsSequentially(segmentPaths);
      }
    } catch (error) {
      voiceCubit.reset();
      setState(() => testErrorMessage = '$error');
    } finally {
      _voicePipelineCancel = null;
      setState(() => testBusy = false);
      _scrollChatToBottom();
    }
  }

  SpeechSynthesisOptions _speechOptionsFromUi({required InstalledModel ttsModel}) {
    final endpointText = streamingTtsEndpointController.text.trim();
    final endpoint = endpointText.isEmpty ? null : Uri.tryParse(endpointText);
    final modelOverride = streamingTtsModelIdController.text.trim();
    final extra = ttsModel.manifest.runtimeConfig.extra;
    final qwenTtsMode = extra['qwen_tts_mode'] as String? ?? '';
    // VoiceDesign: design-prompt tab must not send a stale preset name as `voice`
    // (see LocalAudioRunner.synthesizeSpeech voice_clone routing).
    var voice = qwenTtsMode == 'voice_design' && !_ttsVoiceDesignUsesPreset
        ? ''
        : _effectiveTtsVoiceForModel(ttsModel);
    // In preset mode (_ttsCloneMode == false) never send reference audio — it
    // would override the chosen speaker and make presets sound identical.
    final refPath = _ttsCloneMode ? ttsReferenceAudioPath : null;
    final refText = _ttsCloneMode ? ttsReferenceTextController.text.trim() : '';
    return SpeechSynthesisOptions(
      voice: voice,
      instruct: ttsInstructController.text.trim(),
      languageCode: _normalizeTtsLanguageCode(ttsLanguageController.text),
      referenceAudioPath: refPath,
      referenceText: refText,
      speed: double.tryParse(ttsSpeedController.text.trim()),
      openAiCompatibleSpeechEndpoint: endpoint,
      openAiSpeechModelId: modelOverride.isEmpty ? null : modelOverride,
      speechResponseFormat: 'opus',
      streamSpeech:
          streamSpeechEnabled && endpoint != null && endpoint.hasAuthority,
    );
  }

  Future<String?> _prepareSpeechOptionsForModel(InstalledModel model) async {
    if (!_supportsReferenceVoiceClone(model)) {
      return null;
    }
    // In preset mode skip all clone preparation — do not auto-fill My Voice.
    if (!_ttsCloneMode) {
      return null;
    }
    if ((ttsReferenceAudioPath == null || ttsReferenceAudioPath!.isEmpty) &&
        myVoiceReferencePath != null &&
        File(myVoiceReferencePath!).existsSync()) {
      await _setTtsReferenceAudioPath(myVoiceReferencePath!);
    } else if (ttsReferenceAudioPath != null &&
        ttsReferenceAudioPath!.isNotEmpty &&
        ttsReferenceTextController.text.trim().isEmpty) {
      await _loadOrTranscribeReferenceTranscript(ttsReferenceAudioPath!);
    }
    return _speechOptionsValidationError(model);
  }

  String? _speechOptionsValidationError(InstalledModel model) {
    if (!_supportsReferenceVoiceClone(model)) {
      return null;
    }
    final presetSpeakers = _ttsVoiceOptions(model.manifest.runtimeConfig);
    final pickedVoice = ttsVoiceController.text.trim();
    if (presetSpeakers.isNotEmpty &&
        pickedVoice.isNotEmpty &&
        presetSpeakers.contains(pickedVoice)) {
      return null;
    }
    if (transcribingReferenceVoice) {
      return 'Reference transcript is still being generated locally. Try again in a moment.';
    }
    if (ttsReferenceAudioPath == null ||
        ttsReferenceAudioPath!.trim().isEmpty) {
      return 'Voice cloning needs a reference voice audio sample. Open Voices, record/import your voice, then use it as Ref Audio.';
    }
    if (ttsReferenceTextController.text.trim().isEmpty) {
      return 'Voice cloning needs Reference transcript for your voice sample. The app can auto-fill it with a local ASR model; otherwise paste exactly what you said in the 3–10 sec sample.';
    }
    return null;
  }

  bool _supportsReferenceVoiceClone(InstalledModel model) {
    final extra = model.manifest.runtimeConfig.extra;
    final mode = extra['qwen_tts_mode'] as String?;
    final id = model.manifest.id.toLowerCase();
    return mode == 'base' ||
        extra['supports_voice_clone'] == true ||
        id.contains('voxcpm2');
  }

  LocalChatParams _chatParamsForModel(InstalledModel model) {
    final tools = _modelSupportsToolCallingUi(model)
        ? _parseToolsListOrEmpty()
        : const <LocalTool>[];
    return LocalChatParams(
      modelId: model.manifest.id,
      maxTokens: int.tryParse(generationMaxTokensController.text.trim()) ?? 256,
      temperature: double.tryParse(generationTemperatureController.text.trim()),
      topP: model.manifest.runtimeAdapter == RuntimeAdapter.mlxVlm
          ? null
          : double.tryParse(generationTopPController.text.trim()),
      enableThinking: _modelSupportsThinking(model)
          ? generationThinkingEnabled
          : null,
      tools: tools,
    );
  }

  Widget _buildChatToolsJsonField(
    InstalledModel model, {
    VoidCallback? onExtraChanged,
    String? helperText,
    int minLines = 4,
    int maxLines = 12,
  }) {
    return TextField(
      controller: chatToolsJsonController,
      minLines: minLines,
      maxLines: maxLines,
      onChanged: (_) {
        setState(() {});
        onExtraChanged?.call();
      },
      enabled: !testBusy,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      decoration: InputDecoration(
        labelText: 'Tools (JSON array)',
        border: const OutlineInputBorder(),
        alignLabelWithHint: true,
        hintText: 'Clear to send no tools',
        helperText:
            helperText ??
            'JSON array of LocalTool objects (name, description, parametersJsonSchema). '
                'Default sample is pre-filled; edit as needed. On tool call, a snackbar appears; '
                'the model receives a JSON stub with ok and receivedArguments.',
        errorText: _chatToolsFieldError(model),
      ),
    );
  }

  Widget _buildChatToolsCompactPanel(InstalledModel model) {
    final theme = Theme.of(context);
    final error = _chatToolsFieldError(model);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        border: Border.all(
          color: error == null
              ? theme.colorScheme.outlineVariant
              : theme.colorScheme.error,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              setState(() => chatToolsExpanded = !chatToolsExpanded);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Icon(
                    Icons.build_circle_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'LLM tools: ${_chatToolsSummary(model)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    chatToolsExpanded ? 'Hide' : 'Edit',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  Icon(
                    chatToolsExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                ],
              ),
            ),
          ),
          if (chatToolsExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(10),
              child: _buildChatToolsJsonField(
                model,
                minLines: 3,
                maxLines: 8,
                helperText:
                    'JSON array of LocalTool objects. Collapse this panel to keep chat history readable.',
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _chatToolsSummary(InstalledModel model) {
    final raw = chatToolsJsonController.text.trim();
    if (raw.isEmpty) {
      return 'disabled';
    }
    try {
      final tools = _parseToolsListOrEmpty();
      if (tools.isEmpty) {
        return 'disabled';
      }
      final names = tools.map((tool) => tool.name).join(', ');
      return '${tools.length} configured ($names)';
    } catch (_) {
      return 'invalid JSON';
    }
  }

  bool _modelSupportsToolCallingUi(InstalledModel model) {
    return model.toolCallingUiSupported;
  }

  List<LocalTool> _parseToolsListOrEmpty() {
    final raw = chatToolsJsonController.text.trim();
    if (raw.isEmpty) {
      return const <LocalTool>[];
    }
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((item) {
          final m = Map<String, Object?>.from(
            (item as Map).map((k, v) => MapEntry('$k', v)),
          );
          return LocalTool.fromJsonMap(m);
        })
        .toList(growable: false);
  }

  String? _chatToolsFieldError(InstalledModel model) {
    if (!_modelSupportsToolCallingUi(model)) {
      return null;
    }
    final raw = chatToolsJsonController.text.trim();
    if (raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return 'Tools JSON must be a JSON array of tool objects.';
      }
      for (final item in decoded) {
        if (item is! Map) {
          return 'Each tool must be a JSON object '
              '(fields: name, description, parametersJsonSchema).';
        }
        LocalTool.fromJsonMap(
          Map<String, Object?>.from(item.map((k, v) => MapEntry('$k', v))),
        );
      }
      return null;
    } catch (e) {
      return 'Invalid tools JSON: $e';
    }
  }

  LmToolRegistry? _chatToolRegistryForSend(InstalledModel model) {
    if (!_modelSupportsToolCallingUi(model)) {
      return null;
    }
    final raw = chatToolsJsonController.text.trim();
    if (raw.isEmpty) {
      return null;
    }
    final tools = _parseToolsListOrEmpty();
    if (tools.isEmpty) {
      return null;
    }
    final reg = LmToolRegistry();
    for (final t in tools) {
      reg.register(t.name, (args) async {
        final payload = <String, Object?>{'tool': t.name, 'arguments': args};
        final summary = _shortJsonForSnackBar(payload);
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text('Tool call: $summary'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return jsonEncode(<String, Object?>{
          'ok': true,
          'tool': t.name,
          'receivedArguments': args,
          if (t.name == 'get_current_time')
            'currentTimeUtc': DateTime.now().toUtc().toIso8601String(),
          'stubResult':
              'Studio UI stub response; replace with real logic in production.',
        });
      });
    }
    return reg;
  }

  String _shortJsonForSnackBar(Object? value, {int maxLen = 220}) {
    final s = jsonEncode(value);
    if (s.length <= maxLen) {
      return s;
    }
    return '${s.substring(0, maxLen)}…';
  }

  bool _modelSupportsThinking(InstalledModel? model) {
    if (model == null ||
        model.manifest.runtimeAdapter != RuntimeAdapter.mlxLm) {
      return false;
    }
    final text = [
      model.manifest.id,
      model.manifest.displayName,
      model.manifest.source.repo,
    ].join(' ').toLowerCase();
    return text.contains('qwen3');
  }

  String _normalizeTtsLanguageCode(String value) {
    switch (value.trim().toLowerCase()) {
      case 'ru':
      case 'русский':
        return 'russian';
      case 'en':
        return 'english';
      case 'zh':
      case 'cn':
        return 'chinese';
      case 'ja':
        return 'japanese';
      case 'ko':
        return 'korean';
      case 'de':
        return 'german';
      case 'fr':
        return 'french';
      case 'pt':
        return 'portuguese';
      case 'es':
        return 'spanish';
      case 'it':
        return 'italian';
      default:
        return value.trim().toLowerCase();
    }
  }

  void _replaceStreamingAssistant(
    String message, {
    Duration? generationDuration,
    double? progress,
  }) {
    if (!mounted) {
      return;
    }
    setState(() {
      final lastIndex = controller.chatTurns.lastIndexWhere(
        (turn) => !turn.isUser,
      );
      if (lastIndex == -1) {
        controller.chatTurns.add(
          ChatTurn.assistant(
            message,
            generationDuration: generationDuration,
            progress: progress,
          ),
        );
      } else {
        final current = controller.chatTurns[lastIndex];
        controller.chatTurns[lastIndex] = ChatTurn.assistant(
          message,
          audioPath: current.audioPath,
          imagePath: current.imagePath,
          duration: current.duration,
          generationDuration: generationDuration ?? current.generationDuration,
          progress: progress ?? current.progress,
        );
      }
    });
    _scrollChatToBottom();
  }

  Future<void> _toggleAudioPlayback(String path) async {
    try {
      if (playingAudioPath == path) {
        await audioPlayer.stop();
        if (mounted) {
          setState(() => playingAudioPath = null);
        }
        return;
      }
      await _playAudioPath(path);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => testErrorMessage = 'Could not play audio file.\n$error');
    }
  }

  Future<void> _playAudioPath(String path) async {
    if (!File(path).existsSync()) {
      throw StateError('Audio file no longer exists: $path');
    }
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
    try {
      if (!File(path).existsSync()) {
        return null;
      }
      await audioPlayer.setSource(DeviceFileSource(path));
      return audioPlayer.getDuration();
    } catch (_) {
      return null;
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _formatGenerationDuration(Duration duration) {
    if (duration.inMilliseconds < 1000) {
      return '${duration.inMilliseconds} ms';
    }
    final seconds = duration.inMilliseconds / 1000;
    if (seconds < 60) {
      return '${seconds.toStringAsFixed(seconds < 10 ? 1 : 0)} s';
    }
    final minutes = duration.inMinutes;
    final remainingSeconds = duration.inSeconds.remainder(60);
    return '${minutes}m ${remainingSeconds}s';
  }

  String _formatOptionalDuration(Duration? duration) {
    return duration == null ? '—' : _formatGenerationDuration(duration);
  }

  String _e2eStatusLabel(_E2eBenchmarkStatus status) {
    switch (status) {
      case _E2eBenchmarkStatus.running:
        return 'Running';
      case _E2eBenchmarkStatus.passed:
        return 'Passed';
      case _E2eBenchmarkStatus.failed:
        return 'Failed';
      case _E2eBenchmarkStatus.skipped:
        return 'Skipped';
    }
  }

  Color _e2eStatusColor(_E2eBenchmarkStatus status) {
    switch (status) {
      case _E2eBenchmarkStatus.running:
        return const Color(0xFFBFA5FF);
      case _E2eBenchmarkStatus.passed:
        return const Color(0xFF72E0B0);
      case _E2eBenchmarkStatus.failed:
        return Theme.of(context).colorScheme.error;
      case _E2eBenchmarkStatus.skipped:
        return Theme.of(context).colorScheme.outline;
    }
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    final date =
        '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    return '$date $time';
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
    if (model.dedicatedSpeechToTextModel) {
      return 'audio';
    }
    if (model.audioPromptSupported) {
      return 'audio chat';
    }
    if (model.textPromptSupported) {
      return 'chat';
    }
    return 'installed';
  }

  Future<void> _refreshInstalledModelMetadata(InstalledModel model) async {
    final updated = await controller.refreshInstalledModelMetadata(model);
    _replaceSelectedModelReferences(updated);
  }

  Future<void> _refreshAllInstalledModelMetadata() async {
    await controller.refreshAllInstalledModelMetadata();
    _replaceSelectedModelReferences(null);
  }

  void _replaceSelectedModelReferences(InstalledModel? updated) {
    InstalledModel? resolve(InstalledModel? selected) {
      if (selected == null) {
        return null;
      }
      return _firstWhereOrNull(
            controller.installedModels,
            (model) => model.directory.path == selected.directory.path,
          ) ??
          selected;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      if (updated != null) {
        if (selectedTestModel?.directory.path == updated.directory.path) {
          selectedTestModel = updated;
        }
        if (selectedAsrModel?.directory.path == updated.directory.path) {
          selectedAsrModel = updated;
        }
        if (selectedVoiceChatModel?.directory.path == updated.directory.path) {
          selectedVoiceChatModel = updated;
        }
        if (selectedTtsModel?.directory.path == updated.directory.path) {
          selectedTtsModel = updated;
        }
        return;
      }
      selectedTestModel = resolve(selectedTestModel);
      selectedAsrModel = resolve(selectedAsrModel);
      selectedVoiceChatModel = resolve(selectedVoiceChatModel);
      selectedTtsModel = resolve(selectedTtsModel);
    });
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

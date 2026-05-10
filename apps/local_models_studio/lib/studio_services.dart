import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:local_models_core/local_models_core.dart';
import 'package:path/path.dart' as p;

const _installMetadataFileName = '.flutter_local_model.json';

enum DownloadSourceKind { huggingFace, githubRelease }

enum DownloadTaskStatus {
  queued,
  running,
  paused,
  canceled,
  installing,
  completed,
  failed,
}

class StudioPaths {
  StudioPaths({required this.baseDirectory});

  final Directory baseDirectory;

  Directory get downloadsDirectory =>
      Directory(p.join(baseDirectory.path, 'downloads'));
  Directory get modelsDirectory =>
      Directory(p.join(baseDirectory.path, 'models'));

  static StudioPaths forCurrentUser({String? homeDirectory}) {
    final home = homeDirectory ?? Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return StudioPaths(
        baseDirectory: Directory(
          p.join(Directory.current.path, '.flutter_local_models'),
        ),
      );
    }

    final containerDirectory = Directory(
      p.join(
        home,
        'Library',
        'Containers',
        'com.example.localModelsStudio',
        'Data',
        'Library',
        'Application Support',
        'flutter_local_models',
      ),
    );
    if (containerDirectory.existsSync()) {
      return StudioPaths(baseDirectory: containerDirectory);
    }

    return StudioPaths(
      baseDirectory: Directory(
        p.join(home, 'Library', 'Application Support', 'flutter_local_models'),
      ),
    );
  }
}

class RemoteFileDescriptor {
  const RemoteFileDescriptor({
    required this.relativePath,
    required this.downloadUri,
    this.sizeBytes,
    this.sha256,
  });

  final String relativePath;
  final Uri downloadUri;
  final int? sizeBytes;
  final String? sha256;

  RemoteFileDescriptor copyWith({
    String? relativePath,
    Uri? downloadUri,
    int? sizeBytes,
    String? sha256,
  }) {
    return RemoteFileDescriptor(
      relativePath: relativePath ?? this.relativePath,
      downloadUri: downloadUri ?? this.downloadUri,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      sha256: sha256 ?? this.sha256,
    );
  }
}

class HuggingFaceRepoDetails {
  const HuggingFaceRepoDetails({
    required this.repoId,
    required this.revision,
    required this.gated,
    required this.pipelineTag,
    required this.files,
  });

  final String repoId;
  final String revision;
  final bool gated;
  final String? pipelineTag;
  final List<RemoteFileDescriptor> files;

  int? get totalKnownBytes {
    if (files.any((file) => file.sizeBytes == null)) {
      return null;
    }
    return files.fold<int>(0, (sum, file) => sum + (file.sizeBytes ?? 0));
  }
}

class GitHubReleaseAsset {
  const GitHubReleaseAsset({
    required this.name,
    required this.sizeBytes,
    required this.downloadUri,
    this.sha256,
    this.contentType,
  });

  final String name;
  final int sizeBytes;
  final Uri downloadUri;
  final String? sha256;
  final String? contentType;
}

class GitHubReleaseRecord {
  const GitHubReleaseRecord({
    required this.tagName,
    required this.title,
    required this.assets,
    this.manifest,
  });

  final String tagName;
  final String title;
  final List<GitHubReleaseAsset> assets;
  final LocalModelManifest? manifest;

  bool get hasBundleAssets => assets.any(
    (asset) =>
        asset.name.contains('.part-') || asset.name == 'release_metadata.json',
  );
}

class InstalledModel {
  const InstalledModel({
    required this.manifest,
    required this.directory,
    required this.sourceLabel,
    required this.installedAt,
    required this.sizeBytes,
  });

  final LocalModelManifest manifest;
  final Directory directory;
  final String sourceLabel;
  final DateTime installedAt;
  final int sizeBytes;

  bool get chatSupported =>
      manifest.tasks.contains(ModelTask.chat) &&
      manifest.runtimeAdapter == RuntimeAdapter.mlxLm;

  bool get textPromptSupported =>
      manifest.tasks.contains(ModelTask.chat) &&
      (manifest.runtimeAdapter == RuntimeAdapter.mlxLm ||
          manifest.runtimeAdapter == RuntimeAdapter.mlxVlm);

  bool get audioPromptSupported =>
      manifest.tasks.contains(ModelTask.audioInput) &&
      manifest.runtimeAdapter == RuntimeAdapter.mlxVlm;

  bool get speechToTextSupported =>
      manifest.tasks.contains(ModelTask.speechToText) &&
      manifest.runtimeAdapter == RuntimeAdapter.mlxAudio;

  bool get textToSpeechSupported =>
      manifest.tasks.contains(ModelTask.textToSpeech) &&
      manifest.runtimeAdapter == RuntimeAdapter.mlxAudio;
}

class ChatTurn {
  const ChatTurn.user(this.message) : isUser = true;
  const ChatTurn.assistant(this.message) : isUser = false;

  final bool isUser;
  final String message;
}

class DownloadTaskRecord {
  DownloadTaskRecord({
    required this.id,
    required this.title,
    required this.sourceKind,
    required this.modelId,
    required this.sourceLabel,
    required this.stageDirectory,
    required this.files,
    required this.installer,
  });

  final String id;
  final String title;
  final DownloadSourceKind sourceKind;
  final String modelId;
  final String sourceLabel;
  final Directory stageDirectory;
  final List<RemoteFileDescriptor> files;
  final Future<InstalledModel> Function(DownloadTaskRecord record) installer;

  DownloadTaskStatus status = DownloadTaskStatus.queued;
  int downloadedBytes = 0;
  int totalBytes = 0;
  String? errorMessage;
  String? installedPath;
  bool pauseRequested = false;
  bool cancelRequested = false;

  double? get progress => totalBytes > 0 ? downloadedBytes / totalBytes : null;

  bool get canPause => status == DownloadTaskStatus.running;
  bool get canResume =>
      status == DownloadTaskStatus.paused ||
      status == DownloadTaskStatus.failed;
  bool get canCancel =>
      status == DownloadTaskStatus.running ||
      status == DownloadTaskStatus.paused ||
      status == DownloadTaskStatus.queued;
  bool get canClear =>
      status == DownloadTaskStatus.completed ||
      status == DownloadTaskStatus.canceled ||
      status == DownloadTaskStatus.failed;
}

class StudioApiClient {
  StudioApiClient({
    this.githubOwner = 'IstiN',
    this.githubRepository = 'flutter_local_models',
  });

  final String githubOwner;
  final String githubRepository;

  Future<List<GitHubReleaseRecord>> fetchGitHubReleases(
    ModelRegistry registry,
  ) async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/$githubOwner/$githubRepository/releases',
    );
    final response = await _requestJson(uri);
    final releases = jsonDecode(response) as List<dynamic>;
    return releases
        .cast<Map<String, dynamic>>()
        .map((release) {
          final manifest = _firstWhereOrNull(
            registry.manifests,
            (item) => item.packaging.releaseTag == release['tag_name'],
          );
          final assets = (release['assets'] as List<dynamic>? ?? const [])
              .cast<Map<String, dynamic>>()
              .map(
                (asset) => GitHubReleaseAsset(
                  name: asset['name'] as String,
                  sizeBytes: (asset['size'] as num?)?.toInt() ?? 0,
                  downloadUri: Uri.parse(
                    asset['browser_download_url'] as String,
                  ),
                  sha256: _stripShaPrefix(asset['digest'] as String?),
                  contentType: asset['content_type'] as String?,
                ),
              )
              .toList(growable: false);
          return GitHubReleaseRecord(
            tagName: release['tag_name'] as String,
            title: (release['name'] as String?)?.trim().isNotEmpty == true
                ? release['name'] as String
                : release['tag_name'] as String,
            assets: assets,
            manifest: manifest,
          );
        })
        .toList(growable: false);
  }

  Future<HuggingFaceRepoDetails> fetchHuggingFaceRepo(
    String repoId, {
    String revision = 'main',
    String? token,
  }) async {
    final uri = Uri.https('huggingface.co', '/api/models/$repoId');
    final response = await _requestJson(
      uri,
      headers: _authorizationHeaders(token),
    );
    final decoded = jsonDecode(response) as Map<String, dynamic>;
    final siblings = (decoded['siblings'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    final files = siblings
        .map((sibling) {
          final relativePath = sibling['rfilename'] as String;
          final lfs = sibling['lfs'] as Map<String, dynamic>?;
          return RemoteFileDescriptor(
            relativePath: relativePath,
            downloadUri: Uri.https(
              'huggingface.co',
              '/$repoId/resolve/$revision/$relativePath',
            ),
            sizeBytes:
                (sibling['size'] as num?)?.toInt() ??
                (lfs?['size'] as num?)?.toInt(),
            sha256:
                lfs?['sha256'] as String? ??
                _stripShaPrefix(lfs?['oid'] as String?),
          );
        })
        .toList(growable: false);

    return HuggingFaceRepoDetails(
      repoId: repoId,
      revision: revision,
      gated: decoded['gated'] as bool? ?? false,
      pipelineTag: decoded['pipeline_tag'] as String?,
      files: files,
    );
  }

  Future<List<RemoteFileDescriptor>> hydrateHuggingFaceFiles(
    HuggingFaceRepoDetails details, {
    String? token,
  }) async {
    final hydrated = <RemoteFileDescriptor>[];
    for (final file in details.files) {
      if (file.sizeBytes != null) {
        hydrated.add(file);
        continue;
      }
      final size = await probeRemoteFileSize(
        file.downloadUri,
        headers: _authorizationHeaders(token),
      );
      hydrated.add(file.copyWith(sizeBytes: size));
    }
    return hydrated;
  }

  Future<int?> probeRemoteFileSize(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    try {
      final response = await _runCurl(
        uri,
        extraArgs: const <String>['-I'],
        headers: headers,
      );
      final headLength = _parseContentLength(response);
      if (headLength != null && headLength > 0) {
        return headLength;
      }
    } catch (_) {}

    final response = await _runCurl(
      uri,
      extraArgs: const <String>['-r', '0-0', '-D', '-', '-o', '/dev/null'],
      headers: headers,
    );
    return _parseContentRangeLength(response);
  }

  Future<String> _requestJson(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    return _runCurl(
      uri,
      headers: <String, String>{
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.userAgentHeader: 'flutter_local_models/0.1',
        ...headers,
      },
    );
  }
}

class LocalChatRunner {
  LocalChatRunner({String? pythonExecutable})
    : pythonExecutable = pythonExecutable ?? _resolveMlxPythonExecutable();

  final String pythonExecutable;

  List<String> _buildGenerateArgs({
    required InstalledModel model,
    required String prompt,
    String? audioPath,
    String? imagePath,
    int maxTokens = 256,
  }) {
    return switch (model.manifest.runtimeAdapter) {
      RuntimeAdapter.mlxLm => <String>[
        '-m',
        'mlx_lm',
        'generate',
        '--model',
        model.directory.path,
        '--prompt',
        prompt,
        '--max-tokens',
        '$maxTokens',
        '--verbose',
        'false',
      ],
      RuntimeAdapter.mlxVlm => <String>[
        '-m',
        'mlx_vlm',
        'generate',
        '--model',
        model.directory.path,
        if (audioPath != null) ...<String>['--audio', audioPath],
        if (imagePath != null) ...<String>['--image', imagePath],
        '--prompt',
        prompt,
        '--max-tokens',
        '$maxTokens',
      ],
      _ => throw StateError('Unsupported text runtime.'),
    };
  }

  void _checkRuntime(InstalledModel model) {
    if (!model.textPromptSupported) {
      throw StateError(
        'Chat verification currently supports installed mlx_lm and mlx_vlm chat models.',
      );
    }
    final executableFile = File(pythonExecutable);
    if (!executableFile.existsSync()) {
      throw StateError(
        'MLX Python runtime not found at $pythonExecutable. Set up ~/.venvs/mlx first.',
      );
    }
  }

  Future<String> generateResponse({
    required InstalledModel model,
    required String prompt,
    String? audioPath,
    String? imagePath,
    int maxTokens = 256,
  }) async {
    _checkRuntime(model);
    final args = _buildGenerateArgs(
      model: model,
      prompt: prompt,
      audioPath: audioPath,
      imagePath: imagePath,
      maxTokens: maxTokens,
    );

    final result = await Process.run(pythonExecutable, args);
    if (result.exitCode != 0) {
      throw StateError(
        'Local generation failed: ${(result.stderr as String).trim()}',
      );
    }
    final output = _cleanGeneratedText(result.stdout as String).trim();
    if (output.isEmpty) {
      throw StateError('Local generation returned an empty response.');
    }
    return output;
  }

  Future<String> generateResponseStreaming({
    required InstalledModel model,
    required String prompt,
    required ValueChanged<String> onText,
    String? audioPath,
    String? imagePath,
    int maxTokens = 256,
  }) async {
    _checkRuntime(model);
    final args = _buildGenerateArgs(
      model: model,
      prompt: prompt,
      audioPath: audioPath,
      imagePath: imagePath,
      maxTokens: maxTokens,
    );
    final process = await Process.start(pythonExecutable, args);
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final stdoutDone = process.stdout.transform(utf8.decoder).listen((chunk) {
      stdoutBuffer.write(chunk);
      final cleaned = _cleanGeneratedText(stdoutBuffer.toString()).trim();
      if (cleaned.isNotEmpty) {
        onText(cleaned);
      }
    }).asFuture<void>();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(stderrBuffer.write)
        .asFuture<void>();
    final exitCode = await process.exitCode;
    await stdoutDone;
    await stderrDone;
    if (exitCode != 0) {
      final stderr = stderrBuffer.toString().trim();
      throw StateError(
        'Local generation failed: ${stderr.isEmpty ? 'exit code $exitCode' : stderr}',
      );
    }
    final output = _cleanGeneratedText(stdoutBuffer.toString()).trim();
    if (output.isEmpty) {
      throw StateError('Local generation returned an empty response.');
    }
    onText(output);
    return output;
  }
}

String _cleanGeneratedText(String rawOutput) {
  var text = rawOutput.trim();
  const modelMarker = '<|turn>model';
  final markerIndex = text.indexOf(modelMarker);
  if (markerIndex != -1) {
    text = text.substring(markerIndex + modelMarker.length);
    final separatorIndex = text.indexOf('==========');
    if (separatorIndex != -1) {
      text = text.substring(0, separatorIndex);
    }
  }

  final lines = const LineSplitter()
      .convert(text)
      .where((line) {
        final trimmed = line.trim();
        return trimmed.isNotEmpty &&
            trimmed != '==========' &&
            !trimmed.startsWith('Files:') &&
            !trimmed.startsWith('Prompt:') &&
            !trimmed.startsWith('Generation:') &&
            !trimmed.startsWith('Peak memory:');
      })
      .toList(growable: false);
  return lines.join('\n').trim();
}

class LocalAudioRunner {
  LocalAudioRunner({String? pythonExecutable})
    : pythonExecutable = pythonExecutable ?? _resolveMlxPythonExecutable();

  final String pythonExecutable;

  void _checkRuntime() {
    final executableFile = File(pythonExecutable);
    if (!executableFile.existsSync()) {
      throw StateError(
        'MLX Python runtime not found at $pythonExecutable. Set up ~/.venvs/mlx first.',
      );
    }
  }

  Future<String> transcribeAudio({
    required InstalledModel model,
    required String audioPath,
    String? language,
  }) async {
    if (!model.speechToTextSupported) {
      throw StateError(
        'Audio verification currently supports only installed mlx_audio speech-to-text models.',
      );
    }

    _checkRuntime();

    final tempDirectory = await Directory.systemTemp.createTemp(
      'flm-stt-${sanitizeId(model.manifest.id)}-',
    );
    final outputStem = p.join(tempDirectory.path, 'transcript');

    try {
      final result = await Process.run(pythonExecutable, <String>[
        '-m',
        'mlx_audio.stt.generate',
        '--model',
        model.directory.path,
        '--audio',
        audioPath,
        '--output-path',
        outputStem,
        '--format',
        'txt',
        if (language != null && language.trim().isNotEmpty) ...<String>[
          '--language',
          language.trim(),
        ],
      ]);
      if (result.exitCode != 0) {
        final stderr = (result.stderr as String).trim();
        throw StateError(
          'Local transcription failed: ${stderr.isEmpty ? result.stdout : stderr}',
        );
      }

      final outputFile = File('$outputStem.txt');
      if (!outputFile.existsSync()) {
        throw StateError('Transcription finished without producing output.');
      }

      final transcript = (await outputFile.readAsString()).trim();
      if (transcript.isEmpty) {
        throw StateError('Transcription returned an empty result.');
      }
      return transcript;
    } finally {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    }
  }

  Future<File> synthesizeSpeech({
    required InstalledModel model,
    required String text,
  }) async {
    if (!model.textToSpeechSupported) {
      throw StateError(
        'Speech generation currently supports installed mlx_audio text-to-speech models.',
      );
    }
    _checkRuntime();
    final tempDirectory = await Directory.systemTemp.createTemp(
      'flm-tts-${sanitizeId(model.manifest.id)}-',
    );
    final result = await Process.run(pythonExecutable, <String>[
      '-m',
      'mlx_audio.tts.generate',
      '--model',
      model.directory.path,
      '--text',
      text,
      '--output_path',
      tempDirectory.path,
      '--file_prefix',
      'speech-${DateTime.now().millisecondsSinceEpoch}',
      '--audio_format',
      'wav',
      '--join_audio',
    ]);
    if (result.exitCode != 0) {
      final stderr = (result.stderr as String).trim();
      throw StateError(
        'Local speech generation failed: ${stderr.isEmpty ? result.stdout : stderr}',
      );
    }
    final audioFiles =
        tempDirectory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.wav'))
            .toList()
          ..sort((left, right) => left.path.compareTo(right.path));
    if (audioFiles.isEmpty) {
      throw StateError('Speech generation finished without producing audio.');
    }
    return audioFiles.first;
  }
}

class StudioController extends ChangeNotifier {
  StudioController({
    required this.registry,
    required this.runtimeSummary,
    StudioApiClient? apiClient,
    StudioPaths? paths,
    LocalChatRunner? chatRunner,
    LocalAudioRunner? audioRunner,
    this.refreshRemoteSourcesOnInitialize = true,
  }) : apiClient = apiClient ?? StudioApiClient(),
       paths = paths ?? StudioPaths.forCurrentUser(),
       chatRunner = chatRunner ?? LocalChatRunner(),
       audioRunner = audioRunner ?? LocalAudioRunner() {
    hfToken = Platform.environment['HF_TOKEN'] ?? '';
  }

  final ModelRegistry registry;
  final NativeRuntimeSummary runtimeSummary;
  final StudioApiClient apiClient;
  final StudioPaths paths;
  final LocalChatRunner chatRunner;
  final LocalAudioRunner audioRunner;
  final bool refreshRemoteSourcesOnInitialize;

  bool initialized = false;
  bool loadingSources = false;
  String? sourceErrorMessage;
  String hfToken = '';
  String customHfRepoId = '';
  String? customHfErrorMessage;
  HuggingFaceRepoDetails? customHfRepoDetails;
  List<GitHubReleaseRecord> githubReleases = const [];
  final Map<String, HuggingFaceRepoDetails> huggingFaceReposById =
      <String, HuggingFaceRepoDetails>{};
  final Map<String, String> huggingFaceErrorsById = <String, String>{};
  final List<DownloadTaskRecord> downloads = <DownloadTaskRecord>[];
  List<InstalledModel> installedModels = const [];
  InstalledModel? selectedChatModel;
  final List<ChatTurn> chatTurns = <ChatTurn>[];
  bool chatBusy = false;
  String? chatErrorMessage;

  Future<void> initialize() async {
    if (initialized) {
      return;
    }
    initialized = true;
    await _ensureDirectories();
    await reloadInstalledModels();
    if (refreshRemoteSourcesOnInitialize) {
      await refreshSources();
    } else {
      notifyListeners();
    }
  }

  Future<void> refreshSources() async {
    loadingSources = true;
    sourceErrorMessage = null;
    customHfErrorMessage = null;
    notifyListeners();
    try {
      githubReleases = await apiClient.fetchGitHubReleases(registry);
      await Future.wait(
        registry.manifests.map((manifest) async {
          try {
            final repo = await apiClient.fetchHuggingFaceRepo(
              manifest.source.repo,
              revision: manifest.source.revision,
              token: hfTokenOrNull,
            );
            huggingFaceReposById[repo.repoId] = repo;
            huggingFaceErrorsById.remove(repo.repoId);
          } catch (error) {
            huggingFaceErrorsById[manifest.source.repo] = '$error';
          }
        }),
      );
      if (customHfRepoId.trim().isNotEmpty) {
        await loadCustomHuggingFaceRepo(customHfRepoId);
      }
    } catch (error) {
      sourceErrorMessage = '$error';
    } finally {
      loadingSources = false;
      notifyListeners();
    }
  }

  Future<void> loadCustomHuggingFaceRepo(String repoId) async {
    customHfRepoId = repoId.trim();
    customHfRepoDetails = null;
    customHfErrorMessage = null;
    notifyListeners();
    if (customHfRepoId.isEmpty) {
      return;
    }
    try {
      customHfRepoDetails = await apiClient.fetchHuggingFaceRepo(
        customHfRepoId,
        token: hfTokenOrNull,
      );
    } catch (error) {
      customHfErrorMessage = '$error';
    } finally {
      notifyListeners();
    }
  }

  void updateHfToken(String value) {
    hfToken = value.trim();
    notifyListeners();
  }

  String? get hfTokenOrNull => hfToken.trim().isEmpty ? null : hfToken.trim();

  GitHubReleaseRecord? releaseForManifest(LocalModelManifest manifest) {
    return _firstWhereOrNull(
      githubReleases,
      (release) => release.tagName == manifest.packaging.releaseTag,
    );
  }

  bool isManifestInstalled(LocalModelManifest manifest) {
    return installedModels.any((model) => model.manifest.id == manifest.id);
  }

  InstalledModel? installedModelForManifest(LocalModelManifest manifest) {
    return _firstWhereOrNull(
      installedModels,
      (model) => model.manifest.id == manifest.id,
    );
  }

  Future<void> startManifestHuggingFaceDownload(
    LocalModelManifest manifest,
  ) async {
    final rawDetails =
        huggingFaceReposById[manifest.source.repo] ??
        await apiClient.fetchHuggingFaceRepo(
          manifest.source.repo,
          revision: manifest.source.revision,
          token: hfTokenOrNull,
        );
    huggingFaceReposById[rawDetails.repoId] = rawDetails;
    final files = await apiClient.hydrateHuggingFaceFiles(
      rawDetails,
      token: hfTokenOrNull,
    );
    final payloadDir = Directory(
      p.join(
        paths.downloadsDirectory.path,
        'hf-${manifest.id}-${DateTime.now().millisecondsSinceEpoch}',
        manifest.id,
      ),
    );
    final record = DownloadTaskRecord(
      id: 'hf-${manifest.id}-${DateTime.now().microsecondsSinceEpoch}',
      title: manifest.displayName,
      sourceKind: DownloadSourceKind.huggingFace,
      modelId: manifest.id,
      sourceLabel: 'Hugging Face',
      stageDirectory: payloadDir,
      files: files,
      installer: (task) async {
        final installDir = Directory(
          p.join(paths.modelsDirectory.path, manifest.id),
        );
        if (installDir.existsSync()) {
          await installDir.delete(recursive: true);
        }
        await payloadDir.rename(installDir.path);
        await _writeInstallMetadata(
          installDir,
          manifest,
          sourceLabel: 'Hugging Face',
        );
        return InstalledModel(
          manifest: manifest,
          directory: installDir,
          sourceLabel: 'Hugging Face',
          installedAt: DateTime.now(),
          sizeBytes: await _directorySizeBytes(installDir),
        );
      },
    );
    await _startDownloadTask(record);
  }

  Future<void> startCustomHuggingFaceDownload() async {
    final details = customHfRepoDetails;
    if (details == null) {
      throw StateError('Load a Hugging Face repo first.');
    }
    final manifest = _derivedManifestForRepo(details);
    final files = await apiClient.hydrateHuggingFaceFiles(
      details,
      token: hfTokenOrNull,
    );
    final payloadDir = Directory(
      p.join(
        paths.downloadsDirectory.path,
        'hf-${manifest.id}-${DateTime.now().millisecondsSinceEpoch}',
        manifest.id,
      ),
    );
    final record = DownloadTaskRecord(
      id: 'hf-${manifest.id}-${DateTime.now().microsecondsSinceEpoch}',
      title: manifest.displayName,
      sourceKind: DownloadSourceKind.huggingFace,
      modelId: manifest.id,
      sourceLabel: 'Hugging Face',
      stageDirectory: payloadDir,
      files: files,
      installer: (task) async {
        final installDir = Directory(
          p.join(paths.modelsDirectory.path, manifest.id),
        );
        if (installDir.existsSync()) {
          await installDir.delete(recursive: true);
        }
        await payloadDir.rename(installDir.path);
        await _writeInstallMetadata(
          installDir,
          manifest,
          sourceLabel: 'Hugging Face',
        );
        return InstalledModel(
          manifest: manifest,
          directory: installDir,
          sourceLabel: 'Hugging Face',
          installedAt: DateTime.now(),
          sizeBytes: await _directorySizeBytes(installDir),
        );
      },
    );
    await _startDownloadTask(record);
  }

  Future<void> startGitHubReleaseDownload(GitHubReleaseRecord release) async {
    final releaseManifest =
        release.manifest ?? _fallbackManifestForRelease(release);
    final stageDir = Directory(
      p.join(
        paths.downloadsDirectory.path,
        'gh-${release.tagName}-${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
    final files = release.assets
        .map(
          (asset) => RemoteFileDescriptor(
            relativePath: asset.name,
            downloadUri: asset.downloadUri,
            sizeBytes: asset.sizeBytes,
            sha256: asset.sha256,
          ),
        )
        .toList(growable: false);
    final record = DownloadTaskRecord(
      id: 'gh-${release.tagName}-${DateTime.now().microsecondsSinceEpoch}',
      title: release.title,
      sourceKind: DownloadSourceKind.githubRelease,
      modelId: releaseManifest.id,
      sourceLabel: 'GitHub Release',
      stageDirectory: stageDir,
      files: files,
      installer: (task) async {
        final metadataFile = File(
          p.join(stageDir.path, 'release_metadata.json'),
        );
        final manifestFile = File(
          p.join(stageDir.path, 'manifest.source.yaml'),
        );
        LocalModelManifest manifest = releaseManifest;
        if (manifestFile.existsSync()) {
          manifest = LocalModelManifest.fromYaml(
            await manifestFile.readAsString(),
          );
        }
        final metadata =
            jsonDecode(await metadataFile.readAsString())
                as Map<String, dynamic>;
        final partNames =
            ((metadata['parts'] as List<dynamic>? ?? const [])
                    .cast<Map<String, dynamic>>())
                .map((part) => part['file_name'] as String)
                .toList(growable: false);
        final archivePath = p.join(
          stageDir.path,
          metadata['archive_name'] as String,
        );
        await _concatenateFiles(
          partNames.map((name) => File(p.join(stageDir.path, name))).toList(),
          File(archivePath),
        );
        final installDir = Directory(
          p.join(paths.modelsDirectory.path, manifest.id),
        );
        if (installDir.existsSync()) {
          await installDir.delete(recursive: true);
        }
        final result = await Process.run('tar', <String>[
          '-xf',
          archivePath,
          '-C',
          paths.modelsDirectory.path,
        ]);
        if (result.exitCode != 0) {
          throw StateError(
            'Failed to extract release archive: ${result.stderr}',
          );
        }
        await _writeInstallMetadata(
          installDir,
          manifest,
          sourceLabel: 'GitHub Release',
        );
        return InstalledModel(
          manifest: manifest,
          directory: installDir,
          sourceLabel: 'GitHub Release',
          installedAt: DateTime.now(),
          sizeBytes: await _directorySizeBytes(installDir),
        );
      },
    );
    await _startDownloadTask(record);
  }

  Future<void> reloadInstalledModels() async {
    await _ensureDirectories();
    final discovered = <InstalledModel>[];
    await for (final entity in paths.modelsDirectory.list()) {
      if (entity is! Directory) {
        continue;
      }
      final sizeBytes = await _directorySizeBytes(entity);
      final metadataFile = File(p.join(entity.path, _installMetadataFileName));
      if (metadataFile.existsSync()) {
        final decoded =
            jsonDecode(await metadataFile.readAsString())
                as Map<String, dynamic>;
        final manifest = LocalModelManifest.fromJsonMap(
          Map<String, Object?>.from(decoded['manifest'] as Map),
        );
        discovered.add(
          InstalledModel(
            manifest: manifest,
            directory: entity,
            sourceLabel: decoded['sourceLabel'] as String? ?? 'Unknown',
            installedAt:
                DateTime.tryParse(decoded['installedAt'] as String? ?? '') ??
                DateTime.now(),
            sizeBytes: sizeBytes,
          ),
        );
        continue;
      }
      final manifest = _firstWhereOrNull(
        registry.manifests,
        (item) => item.id == p.basename(entity.path),
      );
      if (manifest != null) {
        discovered.add(
          InstalledModel(
            manifest: manifest,
            directory: entity,
            sourceLabel: 'Unknown',
            installedAt: (await entity.stat()).modified,
            sizeBytes: sizeBytes,
          ),
        );
      }
    }
    discovered.sort(
      (left, right) =>
          left.manifest.displayName.compareTo(right.manifest.displayName),
    );
    installedModels = List<InstalledModel>.unmodifiable(discovered);
    if (selectedChatModel != null) {
      selectedChatModel = _firstWhereOrNull(
        installedModels,
        (model) => model.directory.path == selectedChatModel!.directory.path,
      );
    }
    notifyListeners();
  }

  Future<void> deleteInstalledModel(InstalledModel model) async {
    if (model.directory.existsSync()) {
      await model.directory.delete(recursive: true);
    }
    if (selectedChatModel?.directory.path == model.directory.path) {
      selectedChatModel = null;
      chatTurns.clear();
      chatErrorMessage = null;
    }
    await reloadInstalledModels();
  }

  void selectChatModel(InstalledModel? model) {
    selectedChatModel = model;
    notifyListeners();
  }

  Future<void> sendChatPrompt(String prompt) async {
    final model = selectedChatModel;
    final trimmedPrompt = prompt.trim();
    if (model == null || trimmedPrompt.isEmpty) {
      return;
    }
    chatErrorMessage = null;
    chatBusy = true;
    chatTurns.add(ChatTurn.user(trimmedPrompt));
    notifyListeners();
    try {
      final response = await chatRunner.generateResponse(
        model: model,
        prompt: trimmedPrompt,
      );
      chatTurns.add(ChatTurn.assistant(response));
    } catch (error) {
      chatErrorMessage = '$error';
    } finally {
      chatBusy = false;
      notifyListeners();
    }
  }

  Future<String> transcribeAudio({
    required InstalledModel model,
    required String audioPath,
    String? language,
  }) {
    return audioRunner.transcribeAudio(
      model: model,
      audioPath: audioPath,
      language: language,
    );
  }

  Future<File> synthesizeSpeech({
    required InstalledModel model,
    required String text,
  }) {
    return audioRunner.synthesizeSpeech(model: model, text: text);
  }

  void clearChat() {
    chatTurns.clear();
    chatErrorMessage = null;
    notifyListeners();
  }

  void pauseDownload(DownloadTaskRecord record) {
    record.pauseRequested = true;
    notifyListeners();
  }

  Future<void> resumeDownload(DownloadTaskRecord record) async {
    if (!record.canResume) {
      return;
    }
    record.pauseRequested = false;
    record.cancelRequested = false;
    record.errorMessage = null;
    notifyListeners();
    unawaited(_runDownload(record));
  }

  Future<void> cancelDownload(DownloadTaskRecord record) async {
    record.cancelRequested = true;
    if (record.status == DownloadTaskStatus.paused ||
        record.status == DownloadTaskStatus.queued ||
        record.status == DownloadTaskStatus.failed) {
      await _cleanupCanceledTask(record);
    }
    notifyListeners();
  }

  Future<void> clearDownload(DownloadTaskRecord record) async {
    if (record.stageDirectory.existsSync()) {
      await record.stageDirectory.delete(recursive: true);
    }
    downloads.remove(record);
    notifyListeners();
  }

  Future<void> _startDownloadTask(DownloadTaskRecord record) async {
    final duplicate = _firstWhereOrNull(
      downloads,
      (task) =>
          task.modelId == record.modelId &&
          task.sourceKind == record.sourceKind &&
          !task.canClear,
    );
    if (duplicate != null) {
      throw StateError('A download for ${record.title} is already active.');
    }
    downloads.insert(0, record);
    notifyListeners();
    unawaited(_runDownload(record));
  }

  Future<void> _runDownload(DownloadTaskRecord record) async {
    await _ensureDirectories();
    record.status = DownloadTaskStatus.running;
    record.pauseRequested = false;
    record.cancelRequested = false;
    record.errorMessage = null;
    await record.stageDirectory.create(recursive: true);
    record.totalBytes = record.files.fold<int>(
      0,
      (sum, file) => sum + (file.sizeBytes ?? 0),
    );
    record.downloadedBytes = await _existingByteCount(record);
    notifyListeners();
    try {
      for (final file in record.files) {
        await _downloadFile(record, file);
      }
      if (record.cancelRequested) {
        throw _CanceledDownload();
      }
      if (record.pauseRequested) {
        throw _PausedDownload();
      }
      record.status = DownloadTaskStatus.installing;
      notifyListeners();
      final installedModel = await record.installer(record);
      record.status = DownloadTaskStatus.completed;
      record.installedPath = installedModel.directory.path;
      if (record.stageDirectory.existsSync()) {
        await record.stageDirectory.delete(recursive: true);
      }
      await reloadInstalledModels();
    } on _PausedDownload {
      record.status = DownloadTaskStatus.paused;
    } on _CanceledDownload {
      await _cleanupCanceledTask(record);
    } catch (error) {
      record.status = DownloadTaskStatus.failed;
      record.errorMessage = '$error';
    } finally {
      notifyListeners();
    }
  }

  Future<void> _cleanupCanceledTask(DownloadTaskRecord record) async {
    record.status = DownloadTaskStatus.canceled;
    record.downloadedBytes = 0;
    if (record.stageDirectory.existsSync()) {
      await record.stageDirectory.delete(recursive: true);
    }
  }

  Future<void> _downloadFile(
    DownloadTaskRecord record,
    RemoteFileDescriptor file,
  ) async {
    if (record.cancelRequested) {
      throw _CanceledDownload();
    }
    if (record.pauseRequested) {
      throw _PausedDownload();
    }

    final destination = File(
      p.join(record.stageDirectory.path, file.relativePath),
    );
    await destination.parent.create(recursive: true);
    final expectedSize = file.sizeBytes;
    final alreadyWritten = destination.existsSync()
        ? await destination.length()
        : 0;
    if (expectedSize != null && alreadyWritten == expectedSize) {
      if (file.sha256 != null) {
        final digest = await _computeFileSha256(destination);
        if (digest != file.sha256) {
          await destination.delete();
          throw StateError('Checksum mismatch for ${file.relativePath}.');
        }
      }
      return;
    }

    final baselineDownloaded = record.downloadedBytes - alreadyWritten;
    final stderrBuffer = StringBuffer();
    final args = <String>[
      '-L',
      '--fail',
      '--silent',
      '--show-error',
      '--http1.1',
      ..._curlHeaderArgs(<String, String>{
        HttpHeaders.userAgentHeader: 'flutter_local_models/0.1',
        ..._authorizationHeaders(
          record.sourceKind == DownloadSourceKind.huggingFace
              ? hfTokenOrNull
              : null,
        ),
      }),
      if (alreadyWritten > 0) ...<String>['-C', '-'],
      '-o',
      destination.path,
      file.downloadUri.toString(),
    ];

    final process = await Process.start(_curlExecutable, args);
    final stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .listen(stderrBuffer.write);
    final stdoutSubscription = process.stdout.listen((_) {});
    final monitor = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (record.cancelRequested || record.pauseRequested) {
        process.kill(ProcessSignal.sigterm);
        return;
      }
      if (!destination.existsSync()) {
        return;
      }
      destination.length().then((currentLength) {
        record.downloadedBytes = baselineDownloaded + currentLength;
        notifyListeners();
      });
    });

    try {
      final exitCode = await process.exitCode;
      monitor.cancel();
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();

      if (record.cancelRequested) {
        throw _CanceledDownload();
      }
      if (record.pauseRequested) {
        throw _PausedDownload();
      }
      if (exitCode != 0) {
        final stderrText = stderrBuffer.toString().trim();
        throw HttpException(
          'Download failed for ${file.relativePath}: '
          '${stderrText.isEmpty ? 'curl exited with code $exitCode' : stderrText}',
        );
      }

      final finalLength = destination.existsSync()
          ? await destination.length()
          : 0;
      record.downloadedBytes = baselineDownloaded + finalLength;
      notifyListeners();

      if (expectedSize != null && finalLength != expectedSize) {
        throw StateError('Unexpected file size for ${file.relativePath}.');
      }
      if (file.sha256 != null) {
        final digest = await _computeFileSha256(destination);
        if (digest != file.sha256) {
          throw StateError('Checksum mismatch for ${file.relativePath}.');
        }
      }
    } finally {
      monitor.cancel();
    }
  }

  Future<int> _existingByteCount(DownloadTaskRecord record) async {
    var total = 0;
    for (final file in record.files) {
      final target = File(
        p.join(record.stageDirectory.path, file.relativePath),
      );
      if (target.existsSync()) {
        total += await target.length();
      }
    }
    return total;
  }

  Future<int> _directorySizeBytes(Directory directory) async {
    var total = 0;
    if (!directory.existsSync()) {
      return total;
    }
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      try {
        total += await entity.length();
      } on FileSystemException {
        continue;
      }
    }
    return total;
  }

  Future<void> _ensureDirectories() async {
    await paths.baseDirectory.create(recursive: true);
    await paths.downloadsDirectory.create(recursive: true);
    await paths.modelsDirectory.create(recursive: true);
  }

  Future<void> _writeInstallMetadata(
    Directory modelDirectory,
    LocalModelManifest manifest, {
    required String sourceLabel,
  }) async {
    final metadataFile = File(
      p.join(modelDirectory.path, _installMetadataFileName),
    );
    final payload = <String, Object?>{
      'sourceLabel': sourceLabel,
      'installedAt': DateTime.now().toIso8601String(),
      'manifest': manifest.toJson(),
    };
    await metadataFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  Future<void> _concatenateFiles(List<File> parts, File destination) async {
    if (destination.existsSync()) {
      await destination.delete();
    }
    final sink = destination.openWrite();
    for (final part in parts) {
      await sink.addStream(part.openRead());
    }
    await sink.flush();
    await sink.close();
  }

  LocalModelManifest _fallbackManifestForRelease(GitHubReleaseRecord release) {
    return LocalModelManifest(
      id: sanitizeId(release.tagName.replaceFirst('model-', '')),
      displayName: release.title,
      description: 'Imported model release ${release.tagName}.',
      runtimeAdapter: RuntimeAdapter.nativeBridge,
      tasks: const <ModelTask>[ModelTask.chat],
      source: const ModelSource(
        provider: 'github',
        repo: 'IstiN/flutter_local_models',
        revision: 'main',
        license: 'mit',
      ),
      packaging: PackagingSpec(
        releaseTag: release.tagName,
        archiveName: '${sanitizeId(release.tagName)}.tar',
        chunkSizeBytes: 0,
        assetPrefix: sanitizeId(release.tagName),
      ),
      requirements: const SystemRequirements(
        platform: 'macos-apple-silicon',
        minMemoryGb: 0,
        recommendedMemoryGb: 0,
        notes: <String>['Imported from GitHub release'],
      ),
      capabilities: const CapabilitySpec(
        audioInput: false,
        audioOutput: false,
        toolCalling: false,
      ),
    );
  }

  LocalModelManifest _derivedManifestForRepo(HuggingFaceRepoDetails repo) {
    final knownManifest = _firstWhereOrNull(
      registry.manifests,
      (manifest) => manifest.source.repo == repo.repoId,
    );
    if (knownManifest != null) {
      return knownManifest;
    }
    final pipelineTag = repo.pipelineTag ?? 'text-generation';
    final runtimeAdapter = switch (pipelineTag) {
      'image-text-to-text' => RuntimeAdapter.mlxVlm,
      'text-to-speech' => RuntimeAdapter.mlxAudio,
      'audio-text-to-text' => RuntimeAdapter.mlxAudio,
      'automatic-speech-recognition' => RuntimeAdapter.mlxAudio,
      'any-to-any' => RuntimeAdapter.mlxAudio,
      _ => RuntimeAdapter.mlxLm,
    };
    final tasks = switch (pipelineTag) {
      'image-text-to-text' => const <ModelTask>[
        ModelTask.chat,
        ModelTask.vision,
      ],
      'text-to-speech' => const <ModelTask>[
        ModelTask.textToSpeech,
        ModelTask.audioOutput,
      ],
      'audio-text-to-text' => const <ModelTask>[
        ModelTask.chat,
        ModelTask.audioInput,
      ],
      'automatic-speech-recognition' => const <ModelTask>[
        ModelTask.speechToText,
      ],
      'any-to-any' => const <ModelTask>[ModelTask.chat, ModelTask.audioInput],
      _ => const <ModelTask>[ModelTask.chat],
    };
    final repoName = repo.repoId.split('/').last;
    return LocalModelManifest(
      id: sanitizeId(repoName),
      displayName: repoName.replaceAll('-', ' '),
      description: 'Custom Hugging Face import from ${repo.repoId}.',
      runtimeAdapter: runtimeAdapter,
      tasks: tasks,
      source: ModelSource(
        provider: 'huggingface',
        repo: repo.repoId,
        revision: repo.revision,
        license: 'unknown',
      ),
      packaging: PackagingSpec(
        releaseTag: 'direct-${sanitizeId(repoName)}',
        archiveName: '${sanitizeId(repoName)}.tar',
        chunkSizeBytes: 0,
        assetPrefix: sanitizeId(repoName),
      ),
      requirements: const SystemRequirements(
        platform: 'macos-apple-silicon',
        minMemoryGb: 0,
        recommendedMemoryGb: 0,
        notes: <String>['Custom Hugging Face import'],
      ),
      capabilities: CapabilitySpec(
        audioInput:
            tasks.contains(ModelTask.audioInput) ||
            tasks.contains(ModelTask.speechToText),
        audioOutput:
            tasks.contains(ModelTask.audioOutput) ||
            tasks.contains(ModelTask.textToSpeech),
        toolCalling: false,
      ),
    );
  }
}

Future<String> _computeFileSha256(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

String sanitizeId(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
}

String formatBytes(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  final precision = value >= 10 || unitIndex == 0 ? 0 : 1;
  var formatted = value.toStringAsFixed(precision);
  if (formatted.endsWith('.0')) {
    formatted = formatted.substring(0, formatted.length - 2);
  }
  return '$formatted ${units[unitIndex]}';
}

T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T item) test) {
  for (final item in items) {
    if (test(item)) {
      return item;
    }
  }
  return null;
}

String? _stripShaPrefix(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  return value.startsWith('sha256:') ? value.substring(7) : value;
}

Map<String, String> _authorizationHeaders(String? token) {
  if (token == null || token.isEmpty) {
    return const <String, String>{};
  }
  return <String, String>{HttpHeaders.authorizationHeader: 'Bearer $token'};
}

String _resolveMlxPythonExecutable() {
  final configured = Platform.environment['FLM_MLX_PYTHON'];
  if (configured != null && configured.isNotEmpty) {
    return configured;
  }

  for (final home in _candidateHomeDirectories()) {
    final candidate = p.join(home, '.venvs', 'mlx', 'bin', 'python');
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }

  final fallbackHome = _candidateHomeDirectories().isEmpty
      ? '~'
      : _candidateHomeDirectories().first;
  return p.join(fallbackHome, '.venvs', 'mlx', 'bin', 'python');
}

List<String> _candidateHomeDirectories() {
  final homes = <String>[
    Platform.environment['HOME'] ?? '',
    ..._homeDirectoriesFromProcess(),
  ];
  final seen = <String>{};
  return homes
      .where((home) => home.isNotEmpty)
      .where((home) => seen.add(home))
      .toList(growable: false);
}

List<String> _homeDirectoriesFromProcess() {
  try {
    final result = Process.runSync('/usr/bin/id', const <String>['-un']);
    if (result.exitCode != 0) {
      return const <String>[];
    }
    final username = (result.stdout as String).trim();
    if (username.isEmpty) {
      return const <String>[];
    }
    return <String>['/Users/$username'];
  } catch (_) {
    return const <String>[];
  }
}

List<String> _curlHeaderArgs(Map<String, String> headers) {
  final args = <String>[];
  headers.forEach((key, value) {
    args.add('-H');
    args.add('$key: $value');
  });
  return args;
}

Future<String> _runCurl(
  Uri uri, {
  List<String> extraArgs = const <String>[],
  Map<String, String> headers = const <String, String>{},
}) async {
  final result = await Process.run(_curlExecutable, <String>[
    '-L',
    '--fail',
    '--silent',
    '--show-error',
    '--http1.1',
    ...extraArgs,
    ..._curlHeaderArgs(headers),
    uri.toString(),
  ]);
  if (result.exitCode != 0) {
    final stderr = (result.stderr as String).trim();
    throw HttpException(
      'Request failed for $uri: '
      '${stderr.isEmpty ? 'curl exited with code ${result.exitCode}' : stderr}',
    );
  }
  return result.stdout as String;
}

int? _parseContentLength(String headers) {
  int? parsedLength;
  for (final line in const LineSplitter().convert(headers)) {
    final separatorIndex = line.indexOf(':');
    if (separatorIndex == -1) {
      continue;
    }
    final name = line.substring(0, separatorIndex).trim().toLowerCase();
    if (name != 'content-length') {
      continue;
    }
    parsedLength = int.tryParse(line.substring(separatorIndex + 1).trim());
  }
  return parsedLength;
}

int? _parseContentRangeLength(String headers) {
  int? parsedLength;
  for (final line in const LineSplitter().convert(headers)) {
    final separatorIndex = line.indexOf(':');
    if (separatorIndex == -1) {
      continue;
    }
    final name = line.substring(0, separatorIndex).trim().toLowerCase();
    if (name != 'content-range') {
      continue;
    }
    final value = line.substring(separatorIndex + 1).trim();
    final slashIndex = value.lastIndexOf('/');
    if (slashIndex == -1) {
      continue;
    }
    parsedLength = int.tryParse(value.substring(slashIndex + 1).trim());
  }
  return parsedLength;
}

String get _curlExecutable =>
    File('/usr/bin/curl').existsSync() ? '/usr/bin/curl' : 'curl';

class _PausedDownload implements Exception {}

class _CanceledDownload implements Exception {}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:local_models_core/local_models_core.dart';
import 'package:path/path.dart' as p;

const _installMetadataFileName = '.flutter_local_model.json';
const _downloadQueueFileName = 'download_queue.json';
const _settingsFileName = 'settings.json';

enum DownloadSourceKind { huggingFace, githubRelease }

String _downloadSourceKindToString(DownloadSourceKind value) {
  switch (value) {
    case DownloadSourceKind.huggingFace:
      return 'huggingFace';
    case DownloadSourceKind.githubRelease:
      return 'githubRelease';
  }
}

DownloadSourceKind _downloadSourceKindFromString(String value) {
  switch (value) {
    case 'huggingFace':
      return DownloadSourceKind.huggingFace;
    case 'githubRelease':
      return DownloadSourceKind.githubRelease;
    default:
      throw FormatException('Unsupported download source kind: $value');
  }
}

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
  Directory get voiceReferencesDirectory =>
      Directory(p.join(baseDirectory.path, 'voice_references'));
  File get downloadQueueFile =>
      File(p.join(baseDirectory.path, _downloadQueueFileName));
  File get settingsFile => File(p.join(baseDirectory.path, _settingsFileName));

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

  factory RemoteFileDescriptor.fromJsonMap(Map<String, Object?> map) {
    return RemoteFileDescriptor(
      relativePath: map['relativePath'] as String,
      downloadUri: Uri.parse(map['downloadUri'] as String),
      sizeBytes: (map['sizeBytes'] as num?)?.toInt(),
      sha256: map['sha256'] as String?,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'relativePath': relativePath,
    'downloadUri': downloadUri.toString(),
    if (sizeBytes != null) 'sizeBytes': sizeBytes,
    if (sha256 != null) 'sha256': sha256,
  };
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

class StudioSettings {
  const StudioSettings({
    this.hfToken = '',
    this.githubOwner = 'IstiN',
    this.githubRepository = 'flutter_local_models',
    this.customHfRepoId = '',
    this.maxDownloadRetries = 5,
  });

  final String hfToken;
  final String githubOwner;
  final String githubRepository;
  final String customHfRepoId;
  final int maxDownloadRetries;

  String get githubRepoPath => '$githubOwner/$githubRepository';

  StudioSettings copyWith({
    String? hfToken,
    String? githubOwner,
    String? githubRepository,
    String? customHfRepoId,
    int? maxDownloadRetries,
  }) {
    return StudioSettings(
      hfToken: hfToken ?? this.hfToken,
      githubOwner: githubOwner ?? this.githubOwner,
      githubRepository: githubRepository ?? this.githubRepository,
      customHfRepoId: customHfRepoId ?? this.customHfRepoId,
      maxDownloadRetries: maxDownloadRetries ?? this.maxDownloadRetries,
    );
  }

  factory StudioSettings.fromJsonMap(Map<String, Object?> map) {
    return StudioSettings(
      hfToken: map['hfToken'] as String? ?? '',
      githubOwner: map['githubOwner'] as String? ?? 'IstiN',
      githubRepository:
          map['githubRepository'] as String? ?? 'flutter_local_models',
      customHfRepoId: map['customHfRepoId'] as String? ?? '',
      maxDownloadRetries: (map['maxDownloadRetries'] as num?)?.toInt() ?? 5,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'hfToken': hfToken,
    'githubOwner': githubOwner,
    'githubRepository': githubRepository,
    'customHfRepoId': customHfRepoId,
    'maxDownloadRetries': maxDownloadRetries,
  };
}

class InstalledModel {
  const InstalledModel({
    required this.manifest,
    required this.directory,
    required this.sourceLabel,
    required this.installedAt,
    required this.sizeBytes,
    this.metadataUpdatedAt,
  });

  final LocalModelManifest manifest;
  final Directory directory;
  final String sourceLabel;
  final DateTime installedAt;
  final int sizeBytes;
  final DateTime? metadataUpdatedAt;

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

  bool get imageGenerationSupported =>
      manifest.tasks.contains(ModelTask.imageGeneration) &&
      manifest.runtimeAdapter == RuntimeAdapter.mflux;
}

class ChatTurn {
  const ChatTurn.user(this.message, {this.imagePath})
    : isUser = true,
      audioPath = null,
      duration = null,
      generationDuration = null,
      progress = null;
  const ChatTurn.assistant(
    this.message, {
    this.audioPath,
    this.imagePath,
    this.duration,
    this.generationDuration,
    this.progress,
  }) : isUser = false;

  final bool isUser;
  final String message;
  final String? audioPath;
  final String? imagePath;
  final Duration? duration;
  final Duration? generationDuration;
  final double? progress;
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
    required this.manifest,
  });

  final String id;
  final String title;
  final DownloadSourceKind sourceKind;
  final String modelId;
  final String sourceLabel;
  final Directory stageDirectory;
  final List<RemoteFileDescriptor> files;
  final Future<InstalledModel> Function(DownloadTaskRecord record) installer;
  final LocalModelManifest manifest;

  DownloadTaskStatus status = DownloadTaskStatus.queued;
  int downloadedBytes = 0;
  int totalBytes = 0;
  int downloadSpeedBytesPerSecond = 0;
  int downloadSessionStartBytes = 0;
  DateTime? downloadSessionStartedAt;
  String? errorMessage;
  String? installedPath;
  int retryAttempt = 0;
  bool pauseRequested = false;
  bool cancelRequested = false;

  double? get progress => totalBytes > 0 ? downloadedBytes / totalBytes : null;

  int get effectiveDownloadSpeedBytesPerSecond {
    if (downloadSpeedBytesPerSecond > 0) {
      return downloadSpeedBytesPerSecond;
    }
    final startedAt = downloadSessionStartedAt;
    if (startedAt == null || status != DownloadTaskStatus.running) {
      return 0;
    }
    final elapsedMilliseconds = DateTime.now()
        .difference(startedAt)
        .inMilliseconds;
    final byteDelta = downloadedBytes - downloadSessionStartBytes;
    if (elapsedMilliseconds <= 0 || byteDelta <= 0) {
      return 0;
    }
    return (byteDelta * 1000 / elapsedMilliseconds).round();
  }

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

  factory DownloadTaskRecord.fromJsonMap(
    Map<String, Object?> map,
    Future<InstalledModel> Function(DownloadTaskRecord record) installer,
  ) {
    return DownloadTaskRecord(
        id: map['id'] as String,
        title: map['title'] as String,
        sourceKind: _downloadSourceKindFromString(map['sourceKind'] as String),
        modelId: map['modelId'] as String,
        sourceLabel: map['sourceLabel'] as String,
        stageDirectory: Directory(map['stageDirectory'] as String),
        files: List<Map<String, Object?>>.from(
          map['files'] as List,
        ).map(RemoteFileDescriptor.fromJsonMap).toList(growable: false),
        installer: installer,
        manifest: LocalModelManifest.fromJsonMap(
          Map<String, Object?>.from(map['manifest'] as Map),
        ),
      )
      ..downloadedBytes = (map['downloadedBytes'] as num?)?.toInt() ?? 0
      ..totalBytes = (map['totalBytes'] as num?)?.toInt() ?? 0
      ..retryAttempt = (map['retryAttempt'] as num?)?.toInt() ?? 0
      ..status = DownloadTaskStatus.paused;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'sourceKind': _downloadSourceKindToString(sourceKind),
    'modelId': modelId,
    'sourceLabel': sourceLabel,
    'stageDirectory': stageDirectory.path,
    'files': files.map((file) => file.toJson()).toList(growable: false),
    'manifest': manifest.toJson(),
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    'retryAttempt': retryAttempt,
  };
}

class StudioApiClient {
  StudioApiClient({
    this.githubOwner = 'IstiN',
    this.githubRepository = 'flutter_local_models',
  });

  String githubOwner;
  String githubRepository;

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

  Future<LocalModelManifest?> fetchReleaseManifest(
    GitHubReleaseRecord release,
  ) async {
    final yamlAsset = _firstWhereOrNull(
      release.assets,
      (asset) => asset.name == 'manifest.source.yaml',
    );
    if (yamlAsset != null) {
      return LocalModelManifest.fromYaml(
        await _requestText(yamlAsset.downloadUri),
      );
    }
    final jsonAsset = _firstWhereOrNull(
      release.assets,
      (asset) => asset.name == 'model_metadata.json',
    );
    if (jsonAsset != null) {
      return LocalModelManifest.fromJsonMap(
        Map<String, Object?>.from(
          jsonDecode(await _requestJson(jsonAsset.downloadUri)) as Map,
        ),
      );
    }
    return null;
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
    final override = await hydrateFilesForTesting(details, token: token);
    if (override != null) {
      return override;
    }
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

  @visibleForTesting
  Future<List<RemoteFileDescriptor>?> hydrateFilesForTesting(
    HuggingFaceRepoDetails details, {
    String? token,
  }) async => null;

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

  Future<String> _requestText(Uri uri) async {
    return _runCurl(
      uri,
      headers: const <String, String>{
        HttpHeaders.acceptHeader: 'text/plain, application/x-yaml, */*',
        HttpHeaders.userAgentHeader: 'flutter_local_models/0.1',
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
    double? temperature,
    double? topP,
    bool? enableThinking,
  }) {
    final chatTemplateConfig = enableThinking == null
        ? null
        : jsonEncode({'enable_thinking': enableThinking});
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
        if (temperature != null) ...<String>['--temp', '$temperature'],
        if (topP != null) ...<String>['--top-p', '$topP'],
        if (chatTemplateConfig != null) ...<String>[
          '--chat-template-config',
          chatTemplateConfig,
        ],
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
        if (temperature != null) ...<String>['--temperature', '$temperature'],
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
    double? temperature,
    double? topP,
    bool? enableThinking,
  }) async {
    _checkRuntime(model);
    final args = _buildGenerateArgs(
      model: model,
      prompt: prompt,
      audioPath: audioPath,
      imagePath: imagePath,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      enableThinking: enableThinking,
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
    double? temperature,
    double? topP,
    bool? enableThinking,
  }) async {
    _checkRuntime(model);
    final args = _buildGenerateArgs(
      model: model,
      prompt: prompt,
      audioPath: audioPath,
      imagePath: imagePath,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      enableThinking: enableThinking,
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

  Future<String> chatStream({
    required InstalledModel model,
    required List<LocalChatMessage> messages,
    required ValueChanged<String> onText,
    LocalChatParams params = const LocalChatParams(),
  }) {
    final requestedModelId = params.modelId;
    if (requestedModelId != null && requestedModelId != model.manifest.id) {
      throw StateError(
        'Selected runtime model ${model.manifest.id} does not match requested model $requestedModelId.',
      );
    }
    final prompt = _promptFromMessages(messages);
    final attachments = messages
        .expand((message) => message.attachments)
        .toList(growable: false);
    final audioPath = _lastAttachmentPath(
      attachments,
      LocalAttachmentType.audio,
    );
    final imagePath = _lastAttachmentPath(
      attachments,
      LocalAttachmentType.image,
    );
    return generateResponseStreaming(
      model: model,
      prompt: prompt,
      audioPath: audioPath,
      imagePath: imagePath,
      maxTokens: params.maxTokens,
      temperature: params.temperature,
      topP: params.topP,
      enableThinking: params.enableThinking,
      onText: onText,
    );
  }
}

String _promptFromMessages(List<LocalChatMessage> messages) {
  final buffer = StringBuffer();
  for (final message in messages) {
    final content = message.content.trim();
    if (content.isEmpty) {
      continue;
    }
    buffer.writeln('${localChatRoleToString(message.role)}: $content');
  }
  buffer.write('assistant:');
  return buffer.toString().trim();
}

String? _lastAttachmentPath(
  List<LocalMessageAttachment> attachments,
  LocalAttachmentType type,
) {
  for (final attachment in attachments.reversed) {
    if (attachment.type == type && attachment.filePath != null) {
      return attachment.filePath;
    }
  }
  return null;
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

  text = _stripThinkingBlocks(text);

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

String _stripThinkingBlocks(String text) {
  var cleaned = text;
  final closingIndex = cleaned.lastIndexOf('</think>');
  if (closingIndex != -1) {
    cleaned = cleaned.substring(closingIndex + '</think>'.length);
  }
  while (true) {
    final startIndex = cleaned.indexOf('<think>');
    if (startIndex == -1) {
      return cleaned.trim();
    }
    final endIndex = cleaned.indexOf('</think>', startIndex);
    if (endIndex == -1) {
      return cleaned.substring(0, startIndex).trim();
    }
    cleaned =
        cleaned.substring(0, startIndex) +
        cleaned.substring(endIndex + '</think>'.length);
  }
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
    SpeechSynthesisOptions options = const SpeechSynthesisOptions(),
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
    final runtimeDefaults = model.manifest.runtimeConfig.defaultParameters;
    final audioFormat = runtimeDefaults['audio_format'] as String? ?? 'wav';
    final joinAudio = runtimeDefaults['join_audio'] as bool? ?? true;
    final cfgScale = _numberParameter(runtimeDefaults['cfg_scale']);
    final ddpmSteps = _intParameter(runtimeDefaults['ddpm_steps']);
    final maxTokens =
        _intParameter(runtimeDefaults['max_tokens']) ??
        _intParameter(runtimeDefaults['maxTokens']);
    final temperature = _numberParameter(runtimeDefaults['temperature']);
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
      audioFormat,
      if (options.voice.trim().isNotEmpty) ...<String>[
        '--voice',
        options.voice.trim(),
      ],
      if (options.instruct.trim().isNotEmpty) ...<String>[
        '--instruct',
        options.instruct.trim(),
      ],
      if (options.languageCode.trim().isNotEmpty) ...<String>[
        '--lang_code',
        options.languageCode.trim(),
      ],
      if (options.referenceAudioPath?.trim().isNotEmpty == true) ...<String>[
        '--ref_audio',
        options.referenceAudioPath!.trim(),
      ],
      if (options.referenceText.trim().isNotEmpty) ...<String>[
        '--ref_text',
        options.referenceText.trim(),
      ],
      if (options.speed != null) ...<String>['--speed', '${options.speed}'],
      if (cfgScale != null) ...<String>['--cfg_scale', '$cfgScale'],
      if (ddpmSteps != null) ...<String>['--ddpm_steps', '$ddpmSteps'],
      if (maxTokens != null) ...<String>['--max_tokens', '$maxTokens'],
      if (temperature != null) ...<String>['--temperature', '$temperature'],
      if (joinAudio) '--join_audio',
    ], workingDirectory: tempDirectory.path);
    final stdout = (result.stdout as String).trim();
    final stderr = (result.stderr as String).trim();
    if (result.exitCode != 0) {
      throw StateError(
        _formatSpeechGenerationFailure(
          title: 'Local speech generation failed',
          stdout: stdout,
          stderr: stderr,
          outputDirectory: tempDirectory,
        ),
      );
    }
    final audioFiles = _findGeneratedAudioFiles(
      tempDirectory,
      preferredExtension: audioFormat,
    );
    if (audioFiles.isEmpty) {
      throw StateError(
        _formatSpeechGenerationFailure(
          title: 'Local speech generation finished without producing audio',
          stdout: stdout,
          stderr: stderr,
          outputDirectory: tempDirectory,
        ),
      );
    }
    return audioFiles.first;
  }

  List<File> _findGeneratedAudioFiles(
    Directory directory, {
    required String preferredExtension,
  }) {
    final preferred = preferredExtension
        .replaceFirst('.', '')
        .trim()
        .toLowerCase();
    const audioExtensions = <String>{
      'wav',
      'mp3',
      'm4a',
      'aac',
      'flac',
      'ogg',
      'aif',
      'aiff',
      'caf',
    };
    final extensions = <String>{
      ...audioExtensions,
      if (preferred.isNotEmpty) preferred,
    };
    final files = directory
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) {
          final extension = p
              .extension(file.path)
              .replaceFirst('.', '')
              .toLowerCase();
          if (!extensions.contains(extension)) {
            return false;
          }
          try {
            return file.lengthSync() > 0;
          } on FileSystemException {
            return false;
          }
        })
        .toList(growable: false);
    files.sort((left, right) {
      final leftExtension = p
          .extension(left.path)
          .replaceFirst('.', '')
          .toLowerCase();
      final rightExtension = p
          .extension(right.path)
          .replaceFirst('.', '')
          .toLowerCase();
      final leftPreferred = leftExtension == preferred ? 0 : 1;
      final rightPreferred = rightExtension == preferred ? 0 : 1;
      if (leftPreferred != rightPreferred) {
        return leftPreferred.compareTo(rightPreferred);
      }
      return right.statSync().modified.compareTo(left.statSync().modified);
    });
    return files;
  }

  String _formatSpeechGenerationFailure({
    required String title,
    required String stdout,
    required String stderr,
    required Directory outputDirectory,
  }) {
    final buffer = StringBuffer(title);
    if (_looksLikeMissingKokoroDependency(stdout) ||
        _looksLikeMissingKokoroDependency(stderr)) {
      buffer.writeln(
        '\nMissing Kokoro dependency: install misaki in the MLX runtime with `$pythonExecutable -m pip install misaki`.',
      );
    }
    if (_looksLikeMissingSpacyModel(stdout) ||
        _looksLikeMissingSpacyModel(stderr)) {
      buffer.writeln(
        '\nMissing Kokoro English tokenizer model: install it with `$pythonExecutable -m pip install https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl`.',
      );
    }
    if (_looksLikeMissingEspeak(stdout) || _looksLikeMissingEspeak(stderr)) {
      buffer.writeln(
        '\nMissing Kokoro phoneme fallback: install espeak-ng with `brew install espeak-ng`.',
      );
    }
    if (_looksLikeUnsupportedVoxCpm2(stdout) ||
        _looksLikeUnsupportedVoxCpm2(stderr)) {
      buffer.writeln(
        '\nVoxCPM2 runtime mismatch: PyPI `mlx-audio 0.4.3` does not include the `voxcpm2` backend yet. Install the tested GitHub build in the MLX runtime with `$pythonExecutable -m pip install -U git+https://github.com/Blaizzy/mlx-audio.git@f7c11556eda88731be5cc75ddbdf4a4cb9eeaafc`.',
      );
    }
    buffer.writeln('\nOutput directory: ${outputDirectory.path}');
    if (stdout.isNotEmpty) {
      buffer.writeln('\nstdout:\n${_trimProcessLog(stdout)}');
    }
    if (stderr.isNotEmpty) {
      buffer.writeln('\nstderr:\n${_trimProcessLog(stderr)}');
    }
    final files = _describeDirectoryFiles(outputDirectory);
    if (files.isNotEmpty) {
      buffer.writeln('\nGenerated files:\n$files');
    }
    return buffer.toString().trim();
  }

  bool _looksLikeMissingKokoroDependency(String output) {
    final lower = output.toLowerCase();
    return lower.contains('kokoro requires') && lower.contains('misaki');
  }

  bool _looksLikeMissingSpacyModel(String output) {
    final lower = output.toLowerCase();
    return lower.contains("can't find model 'en_core_web_sm'") ||
        lower.contains('can\'t find model "en_core_web_sm"');
  }

  bool _looksLikeMissingEspeak(String output) {
    return output.toLowerCase().contains('espeak not installed');
  }

  bool _looksLikeUnsupportedVoxCpm2(String output) {
    final lower = output.toLowerCase();
    return lower.contains('model type voxcpm2 not supported') ||
        lower.contains("no module named 'mlx_audio.tts.models.voxcpm2'") ||
        lower.contains('no module named "mlx_audio.tts.models.voxcpm2"');
  }

  String _trimProcessLog(String text) {
    const maxLines = 80;
    const maxCharacters = 6000;
    final lines = const LineSplitter().convert(text);
    final trimmedLines = lines.length > maxLines
        ? <String>[
            ...lines.take(maxLines),
            '… (${lines.length - maxLines} more lines)',
          ]
        : lines;
    final joined = trimmedLines.join('\n');
    if (joined.length <= maxCharacters) {
      return joined;
    }
    return '${joined.substring(0, maxCharacters)}\n… (${joined.length - maxCharacters} more characters)';
  }

  String _describeDirectoryFiles(Directory directory) {
    if (!directory.existsSync()) {
      return '';
    }
    final files =
        directory
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .toList(growable: false)
          ..sort((left, right) => left.path.compareTo(right.path));
    if (files.isEmpty) {
      return '';
    }
    final lines = files
        .take(24)
        .map((file) {
          final relativePath = p.relative(file.path, from: directory.path);
          int sizeBytes = 0;
          try {
            sizeBytes = file.lengthSync();
          } on FileSystemException {
            sizeBytes = 0;
          }
          return '- $relativePath (${formatBytes(sizeBytes)})';
        })
        .toList(growable: false);
    if (files.length > lines.length) {
      lines.add('- … (${files.length - lines.length} more files)');
    }
    return lines.join('\n');
  }
}

class LocalImageRunner {
  LocalImageRunner({String? mfluxExecutable})
    : mfluxExecutable = mfluxExecutable ?? _resolveMfluxExecutable();

  final String mfluxExecutable;

  Future<File> generateImage({
    required InstalledModel model,
    required String prompt,
    ValueChanged<double>? onProgress,
  }) async {
    if (!model.imageGenerationSupported) {
      throw StateError(
        'Image generation currently supports installed mflux text-to-image models.',
      );
    }
    final executable = _mfluxExecutableFor(model);
    final executableFile = File(executable);
    if (executable.contains(p.separator) && !executableFile.existsSync()) {
      throw StateError(
        'mflux image generator not found at $executable. Install/update mflux first.',
      );
    }

    final defaults = model.manifest.runtimeConfig.defaultParameters;
    final width = _intParameter(defaults['width']);
    final height = _intParameter(defaults['height']);
    final steps = _intParameter(defaults['steps']);
    final guidance = _numberParameter(defaults['guidance']);
    final seed = _intParameter(defaults['seed']);
    final outputDir = await Directory.systemTemp.createTemp(
      'flm-image-${sanitizeId(model.manifest.id)}-',
    );
    final outputPath = p.join(
      outputDir.path,
      'image-${DateTime.now().millisecondsSinceEpoch}.png',
    );
    final args = <String>[
      '--model',
      model.directory.path,
      '--prompt',
      prompt,
      '--output',
      outputPath,
      if (width != null) ...<String>['--width', '$width'],
      if (height != null) ...<String>['--height', '$height'],
      if (steps != null) ...<String>['--steps', '$steps'],
      if (guidance != null) ...<String>['--guidance', '$guidance'],
      if (seed != null) ...<String>['--seed', '$seed'],
    ];
    final baseModel = _mfluxBaseModelFor(model);
    if (baseModel != null &&
        (executable.endsWith('mflux-generate') ||
            executable.endsWith('mflux-generate-qwen'))) {
      args.insertAll(2, <String>['--base-model', baseModel]);
    }
    final process = await Process.start(executable, args);
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .listen(stdoutBuffer.write)
        .asFuture<void>();
    final stderrDone = process.stderr.transform(utf8.decoder).listen((chunk) {
      stderrBuffer.write(chunk);
      final progress = _parseMfluxProgress(stderrBuffer.toString());
      if (progress != null) {
        onProgress?.call(progress);
      }
    }).asFuture<void>();
    final exitCode = await process.exitCode;
    await stdoutDone;
    await stderrDone;
    if (exitCode != 0) {
      final stderr = stderrBuffer.toString().trim();
      throw StateError(
        'Local image generation failed using $executable: ${stderr.isEmpty ? stdoutBuffer.toString().trim() : stderr}',
      );
    }
    final outputFile = File(outputPath);
    if (!outputFile.existsSync()) {
      throw StateError('Image generation finished without producing output.');
    }
    onProgress?.call(1);
    return outputFile;
  }

  double? _parseMfluxProgress(String chunk) {
    final percentMatches = RegExp(r'(\d{1,3})%').allMatches(chunk).toList();
    if (percentMatches.isNotEmpty) {
      final percent = int.tryParse(percentMatches.last.group(1)!);
      if (percent != null) {
        return percent.clamp(0, 100).toDouble() / 100;
      }
    }
    final stepMatches = RegExp(r'(\d+)\s*/\s*(\d+)').allMatches(chunk).toList();
    if (stepMatches.isNotEmpty) {
      final current = int.tryParse(stepMatches.last.group(1)!);
      final total = int.tryParse(stepMatches.last.group(2)!);
      if (current != null && total != null && total > 0) {
        return (current / total).clamp(0, 1).toDouble();
      }
    }
    return null;
  }

  String _mfluxExecutableFor(InstalledModel model) {
    final configuredRunner =
        model.manifest.runtimeConfig.extra['mflux_runner'] as String?;
    final identity = [
      configuredRunner ?? '',
      model.manifest.id,
      model.manifest.source.repo,
      model.manifest.displayName,
      p.basename(model.directory.path),
    ].join(' ').toLowerCase();
    final command = identity.contains('qwen')
        ? 'mflux-generate-qwen'
        : identity.contains('z-image-turbo')
        ? 'mflux-generate-z-image-turbo'
        : identity.contains('z-image')
        ? 'mflux-generate-z-image'
        : mfluxExecutable;
    if (command.contains(p.separator)) {
      return command;
    }
    final home = Platform.environment['HOME'] ?? '';
    final candidates = <String>[
      if (home.isNotEmpty) p.join(home, '.local', 'bin', command),
      '/opt/homebrew/bin/$command',
      '/usr/local/bin/$command',
      command,
    ];
    for (final candidate in candidates) {
      if (!candidate.contains(p.separator) || File(candidate).existsSync()) {
        return candidate;
      }
    }
    return command;
  }

  static String? _mfluxBaseModelFor(InstalledModel model) {
    final configuredBaseModel =
        model.manifest.runtimeConfig.extra['mflux_base_model'] as String?;
    if (configuredBaseModel != null && configuredBaseModel.trim().isNotEmpty) {
      return configuredBaseModel.trim();
    }
    final identity = [
      model.manifest.id,
      model.manifest.source.repo,
      model.manifest.displayName,
    ].join(' ').toLowerCase();
    if (identity.contains('schnell')) {
      return 'schnell';
    }
    if (identity.contains('qwen')) {
      return 'qwen';
    }
    if (identity.contains('flux2-klein-9b')) {
      return 'flux2-klein-9b';
    }
    if (identity.contains('flux2-klein-4b')) {
      return 'flux2-klein-4b';
    }
    if (identity.contains('z-image-turbo')) {
      return 'z-image-turbo';
    }
    if (identity.contains('z-image')) {
      return 'z-image';
    }
    return null;
  }
}

String _resolveMfluxExecutable() {
  final home = Platform.environment['HOME'] ?? '';
  final candidates = <String>[
    if ((Platform.environment['MFLUX_GENERATE'] ?? '').isNotEmpty)
      Platform.environment['MFLUX_GENERATE']!,
    if (home.isNotEmpty) p.join(home, '.local', 'bin', 'mflux-generate'),
    '/opt/homebrew/bin/mflux-generate',
    '/usr/local/bin/mflux-generate',
    'mflux-generate',
  ];
  for (final candidate in candidates) {
    if (!candidate.contains(p.separator) || File(candidate).existsSync()) {
      return candidate;
    }
  }
  return candidates.last;
}

int? _intParameter(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

double? _numberParameter(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

class SpeechSynthesisOptions {
  const SpeechSynthesisOptions({
    this.voice = '',
    this.instruct = '',
    this.languageCode = '',
    this.referenceAudioPath,
    this.referenceText = '',
    this.speed,
  });

  final String voice;
  final String instruct;
  final String languageCode;
  final String? referenceAudioPath;
  final String referenceText;
  final double? speed;
}

class StudioController extends ChangeNotifier {
  StudioController({
    required this.registry,
    required this.runtimeSummary,
    StudioApiClient? apiClient,
    StudioPaths? paths,
    LocalChatRunner? chatRunner,
    LocalAudioRunner? audioRunner,
    LocalImageRunner? imageRunner,
    this.refreshRemoteSourcesOnInitialize = true,
  }) : apiClient = apiClient ?? StudioApiClient(),
       paths = paths ?? StudioPaths.forCurrentUser(),
       chatRunner = chatRunner ?? LocalChatRunner(),
       audioRunner = audioRunner ?? LocalAudioRunner(),
       imageRunner = imageRunner ?? LocalImageRunner() {
    hfToken = Platform.environment['HF_TOKEN'] ?? '';
  }

  final ModelRegistry registry;
  final NativeRuntimeSummary runtimeSummary;
  final StudioApiClient apiClient;
  final StudioPaths paths;
  final LocalChatRunner chatRunner;
  final LocalAudioRunner audioRunner;
  final LocalImageRunner imageRunner;
  final bool refreshRemoteSourcesOnInitialize;

  bool initialized = false;
  bool loadingSources = false;
  String? sourceErrorMessage;
  String hfToken = '';
  String customHfRepoId = '';
  int maxDownloadRetries = 5;
  String settingsStatusMessage = '';
  String metadataStatusMessage = '';
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
    await _ensureDirectories();
    await _loadSettings();
    await reloadInstalledModels();
    await _restoreDownloadQueue();
    await _cleanupOrphanDownloadDirectories();
    initialized = true;
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
    await _saveSettings();
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

  Future<void> updateHfToken(String value) async {
    hfToken = value.trim();
    await _saveSettings();
    notifyListeners();
  }

  Future<void> updateSettings({
    required String hfToken,
    required String githubRepoPath,
    required String customHfRepoId,
    required int maxDownloadRetries,
  }) async {
    final parsed = _parseGitHubRepoPath(githubRepoPath);
    this.hfToken = hfToken.trim();
    apiClient.githubOwner = parsed.$1;
    apiClient.githubRepository = parsed.$2;
    this.customHfRepoId = customHfRepoId.trim();
    this.maxDownloadRetries = _clampDownloadRetryCount(maxDownloadRetries);
    settingsStatusMessage = 'Settings saved';
    await _saveSettings();
    notifyListeners();
  }

  String get githubRepoPath =>
      '${apiClient.githubOwner}/${apiClient.githubRepository}';

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
      manifest: manifest,
      installer: _installHuggingFaceDownload,
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
      manifest: manifest,
      installer: _installHuggingFaceDownload,
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
      manifest: releaseManifest,
      installer: _installGitHubReleaseDownload,
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
            metadataUpdatedAt: DateTime.tryParse(
              decoded['metadataUpdatedAt'] as String? ?? '',
            ),
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
            metadataUpdatedAt: null,
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

  Future<InstalledModel> refreshInstalledModelMetadata(
    InstalledModel model,
  ) async {
    final manifest = await _latestManifestForInstalledModel(model);
    await _writeInstallMetadata(
      model.directory,
      manifest,
      sourceLabel: model.sourceLabel,
      installedAt: model.installedAt,
      metadataUpdatedAt: DateTime.now(),
    );
    metadataStatusMessage =
        'Updated config metadata for ${manifest.displayName}';
    await reloadInstalledModels();
    final refreshed = _firstWhereOrNull(
      installedModels,
      (item) => item.directory.path == model.directory.path,
    );
    if (refreshed != null) {
      return refreshed;
    }
    return InstalledModel(
      manifest: manifest,
      directory: model.directory,
      sourceLabel: model.sourceLabel,
      installedAt: model.installedAt,
      metadataUpdatedAt: DateTime.now(),
      sizeBytes: await _directorySizeBytes(model.directory),
    );
  }

  Future<void> refreshAllInstalledModelMetadata() async {
    if (installedModels.isEmpty) {
      metadataStatusMessage = 'No installed models to update';
      notifyListeners();
      return;
    }
    var updatedCount = 0;
    for (final model in List<InstalledModel>.from(installedModels)) {
      await refreshInstalledModelMetadata(model);
      updatedCount += 1;
    }
    metadataStatusMessage =
        'Updated config metadata for $updatedCount installed model${updatedCount == 1 ? '' : 's'}';
    notifyListeners();
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
    SpeechSynthesisOptions options = const SpeechSynthesisOptions(),
  }) {
    final speechText = _sanitizeTextForSpeech(text);
    return audioRunner.synthesizeSpeech(
      model: model,
      text: speechText,
      options: options,
    );
  }

  Future<File> generateImage({
    required InstalledModel model,
    required String prompt,
    ValueChanged<double>? onProgress,
  }) {
    return imageRunner.generateImage(
      model: model,
      prompt: prompt,
      onProgress: onProgress,
    );
  }

  void clearChat() {
    chatTurns.clear();
    chatErrorMessage = null;
    notifyListeners();
  }

  Future<void> _restoreDownloadQueue() async {
    final file = paths.downloadQueueFile;
    if (!file.existsSync()) {
      return;
    }
    try {
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      final restored = decoded
          .cast<Map<String, dynamic>>()
          .map(
            (item) => DownloadTaskRecord.fromJsonMap(
              Map<String, Object?>.from(item),
              _installerForPersistedDownload,
            ),
          )
          .where((record) => record.stageDirectory.existsSync())
          .toList(growable: false);
      downloads
        ..clear()
        ..addAll(restored);
      for (final record in restored) {
        record.downloadedBytes = await _existingByteCount(record);
        record.status = DownloadTaskStatus.paused;
      }
      notifyListeners();
      for (final record in restored) {
        unawaited(_runDownload(record));
      }
    } catch (error) {
      sourceErrorMessage = 'Failed to restore downloads: $error';
      await file.delete().catchError((_) => file);
    }
  }

  Future<void> _persistDownloadQueue() async {
    await _ensureDirectories();
    final active = downloads
        .where(
          (record) =>
              record.status == DownloadTaskStatus.queued ||
              record.status == DownloadTaskStatus.running ||
              record.status == DownloadTaskStatus.paused ||
              record.status == DownloadTaskStatus.failed ||
              record.status == DownloadTaskStatus.installing,
        )
        .map((record) => record.toJson())
        .toList(growable: false);
    final file = paths.downloadQueueFile;
    if (active.isEmpty) {
      if (file.existsSync()) {
        await file.delete();
      }
      return;
    }
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(active),
    );
  }

  Future<void> _loadSettings() async {
    final file = paths.settingsFile;
    if (!file.existsSync()) {
      return;
    }
    try {
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final settings = StudioSettings.fromJsonMap(decoded);
      hfToken = settings.hfToken;
      customHfRepoId = settings.customHfRepoId;
      maxDownloadRetries = _clampDownloadRetryCount(
        settings.maxDownloadRetries,
      );
      apiClient.githubOwner = settings.githubOwner;
      apiClient.githubRepository = settings.githubRepository;
    } catch (error) {
      sourceErrorMessage = 'Failed to load settings: $error';
    }
  }

  Future<void> _saveSettings() async {
    await _ensureDirectories();
    final settings = StudioSettings(
      hfToken: hfToken,
      githubOwner: apiClient.githubOwner,
      githubRepository: apiClient.githubRepository,
      customHfRepoId: customHfRepoId,
      maxDownloadRetries: maxDownloadRetries,
    );
    await paths.settingsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );
  }

  Future<InstalledModel> _installerForPersistedDownload(
    DownloadTaskRecord record,
  ) {
    return switch (record.sourceKind) {
      DownloadSourceKind.huggingFace => _installHuggingFaceDownload(record),
      DownloadSourceKind.githubRelease => _installGitHubReleaseDownload(record),
    };
  }

  Future<InstalledModel> _installHuggingFaceDownload(
    DownloadTaskRecord record,
  ) async {
    final installDir = Directory(
      p.join(paths.modelsDirectory.path, record.manifest.id),
    );
    if (installDir.existsSync()) {
      await installDir.delete(recursive: true);
    }
    await record.stageDirectory.rename(installDir.path);
    await _writeInstallMetadata(
      installDir,
      record.manifest,
      sourceLabel: record.sourceLabel,
    );
    return InstalledModel(
      manifest: record.manifest,
      directory: installDir,
      sourceLabel: record.sourceLabel,
      installedAt: DateTime.now(),
      sizeBytes: await _directorySizeBytes(installDir),
    );
  }

  Future<InstalledModel> _installGitHubReleaseDownload(
    DownloadTaskRecord record,
  ) async {
    final metadataFile = File(
      p.join(record.stageDirectory.path, 'release_metadata.json'),
    );
    final manifestFile = File(
      p.join(record.stageDirectory.path, 'manifest.source.yaml'),
    );
    var manifest = record.manifest;
    if (manifestFile.existsSync()) {
      manifest = LocalModelManifest.fromYaml(await manifestFile.readAsString());
    }
    final metadata =
        jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
    final partNames =
        ((metadata['parts'] as List<dynamic>? ?? const [])
                .cast<Map<String, dynamic>>())
            .map((part) => part['file_name'] as String)
            .toList(growable: false);
    final archivePath = p.join(
      record.stageDirectory.path,
      metadata['archive_name'] as String,
    );
    await _concatenateFiles(
      partNames
          .map((name) => File(p.join(record.stageDirectory.path, name)))
          .toList(),
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
      throw StateError('Failed to extract release archive: ${result.stderr}');
    }
    await _writeInstallMetadata(
      installDir,
      manifest,
      sourceLabel: record.sourceLabel,
    );
    return InstalledModel(
      manifest: manifest,
      directory: installDir,
      sourceLabel: record.sourceLabel,
      installedAt: DateTime.now(),
      sizeBytes: await _directorySizeBytes(installDir),
    );
  }

  void pauseDownload(DownloadTaskRecord record) {
    record.pauseRequested = true;
    unawaited(_persistDownloadQueue());
    notifyListeners();
  }

  Future<void> resumeDownload(DownloadTaskRecord record) async {
    if (!record.canResume) {
      return;
    }
    record.retryAttempt = 0;
    record.pauseRequested = false;
    record.cancelRequested = false;
    record.errorMessage = null;
    notifyListeners();
    unawaited(_persistDownloadQueue());
    unawaited(_runDownload(record));
  }

  Future<void> cancelDownload(DownloadTaskRecord record) async {
    record.cancelRequested = true;
    if (record.status == DownloadTaskStatus.paused ||
        record.status == DownloadTaskStatus.queued ||
        record.status == DownloadTaskStatus.failed) {
      await _cleanupCanceledTask(record);
    }
    await _persistDownloadQueue();
    notifyListeners();
  }

  Future<void> clearDownload(DownloadTaskRecord record) async {
    if (record.stageDirectory.existsSync()) {
      await record.stageDirectory.delete(recursive: true);
    }
    downloads.remove(record);
    await _persistDownloadQueue();
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
    await _persistDownloadQueue();
    notifyListeners();
    unawaited(_runDownload(record));
  }

  Future<void> _runDownload(DownloadTaskRecord record) async {
    await _ensureDirectories();
    record.status = DownloadTaskStatus.running;
    record.downloadSpeedBytesPerSecond = 0;
    record.pauseRequested = false;
    record.cancelRequested = false;
    record.errorMessage = null;
    await record.stageDirectory.create(recursive: true);
    record.totalBytes = record.files.fold<int>(
      0,
      (sum, file) => sum + (file.sizeBytes ?? 0),
    );
    record.downloadedBytes = await _existingByteCount(record);
    record.downloadSessionStartBytes = record.downloadedBytes;
    record.downloadSessionStartedAt = DateTime.now();
    await _persistDownloadQueue();
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
      record.downloadSpeedBytesPerSecond = 0;
      notifyListeners();
      final installedModel = await record.installer(record);
      record.status = DownloadTaskStatus.completed;
      record.installedPath = installedModel.directory.path;
      if (record.stageDirectory.existsSync()) {
        await record.stageDirectory.delete(recursive: true);
      }
      await reloadInstalledModels();
      downloads.remove(record);
      await _persistDownloadQueue();
    } on _PausedDownload {
      record.status = DownloadTaskStatus.paused;
      record.downloadSpeedBytesPerSecond = 0;
      await _persistDownloadQueue();
    } on _CanceledDownload {
      await _cleanupCanceledTask(record);
      await _persistDownloadQueue();
    } catch (error) {
      if (_isRetryableDownloadError(error) &&
          record.retryAttempt < maxDownloadRetries &&
          !record.cancelRequested &&
          !record.pauseRequested) {
        record.retryAttempt += 1;
        record.status = DownloadTaskStatus.running;
        record.downloadSpeedBytesPerSecond = 0;
        record.errorMessage =
            'Retry ${record.retryAttempt}/$maxDownloadRetries after: $error';
        await _persistDownloadQueue();
        notifyListeners();
        await Future<void>.delayed(_retryDelay(record.retryAttempt));
        if (record.cancelRequested) {
          await _cleanupCanceledTask(record);
          await _persistDownloadQueue();
          return;
        }
        if (record.pauseRequested) {
          record.status = DownloadTaskStatus.paused;
          await _persistDownloadQueue();
          return;
        }
        unawaited(_runDownload(record));
        return;
      }
      record.status = DownloadTaskStatus.failed;
      record.downloadSpeedBytesPerSecond = 0;
      final retrySuffix = record.retryAttempt > 0
          ? ' after ${record.retryAttempt}/$maxDownloadRetries retries'
          : '';
      record.errorMessage = '$error$retrySuffix';
      await _persistDownloadQueue();
    } finally {
      notifyListeners();
    }
  }

  Duration _retryDelay(int attempt) {
    final seconds = (1 << (attempt - 1)).clamp(1, 30).toInt();
    return Duration(seconds: seconds);
  }

  bool _isRetryableDownloadError(Object error) {
    if (error is HttpException) {
      final message = error.message.toLowerCase();
      return message.contains('curl: (56)') ||
          message.contains('curl: (18)') ||
          message.contains('curl: (28)') ||
          message.contains('connection reset') ||
          message.contains('connection timed out') ||
          message.contains('transfer closed') ||
          message.contains('recv failure') ||
          message.contains('failed receiving network data');
    }
    if (error is StateError) {
      final message = error.message.toLowerCase();
      return message.contains('unexpected file size');
    }
    return false;
  }

  static int _clampDownloadRetryCount(int value) => value.clamp(0, 50).toInt();

  static String _sanitizeTextForSpeech(String text) {
    final withoutMarkdownLinks = text.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]+\)'),
      (match) => match.group(1) ?? '',
    );
    final cleaned = withoutMarkdownLinks
        .replaceAll(RegExp(r'[*_`#>]'), '')
        .replaceAll(RegExp(r'\s+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return cleaned.isEmpty ? text.trim() : cleaned;
  }

  Future<void> _cleanupCanceledTask(DownloadTaskRecord record) async {
    record.status = DownloadTaskStatus.canceled;
    record.downloadedBytes = 0;
    if (record.stageDirectory.existsSync()) {
      await record.stageDirectory.delete(recursive: true);
    }
    await _persistDownloadQueue();
  }

  Future<void> _cleanupOrphanDownloadDirectories() async {
    if (!paths.downloadsDirectory.existsSync()) {
      return;
    }
    final activeStagePaths = downloads
        .map((record) => p.normalize(record.stageDirectory.path))
        .toSet();
    await for (final entity in paths.downloadsDirectory.list(
      recursive: false,
      followLinks: false,
    )) {
      if (entity is! Directory) {
        continue;
      }
      if (activeStagePaths.contains(p.normalize(entity.path))) {
        continue;
      }
      try {
        await entity.delete(recursive: true);
      } on FileSystemException {
        continue;
      }
    }
  }

  Future<void> _downloadFile(
    DownloadTaskRecord record,
    RemoteFileDescriptor file,
  ) async {
    final destination = File(
      p.join(record.stageDirectory.path, file.relativePath),
    );
    await destination.parent.create(recursive: true);
    final expectedSize = file.sizeBytes;
    var retriedCleanDownload = false;

    while (true) {
      if (record.cancelRequested) {
        throw _CanceledDownload();
      }
      if (record.pauseRequested) {
        throw _PausedDownload();
      }

      var alreadyWritten = destination.existsSync()
          ? await destination.length()
          : 0;
      if (expectedSize != null && alreadyWritten > expectedSize) {
        await destination.delete();
        record.downloadedBytes -= alreadyWritten;
        if (record.downloadedBytes < 0) {
          record.downloadedBytes = 0;
        }
        alreadyWritten = 0;
        await _persistDownloadQueue();
        notifyListeners();
      }

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
      var lastSpeedSampleBytes = record.downloadedBytes;
      var lastSpeedSampleTime = DateTime.now();
      final stderrBuffer = StringBuffer();
      final args = <String>[
        '-L',
        '--fail',
        '--silent',
        '--show-error',
        '--http1.1',
        ..._curlHeaderArgs(<String, String>{
          HttpHeaders.userAgentHeader: 'flutter_local_models/0.1',
          HttpHeaders.acceptHeader: 'application/octet-stream',
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
          final now = DateTime.now();
          final elapsed = now.difference(lastSpeedSampleTime);
          if (elapsed.inMilliseconds >= 750) {
            final byteDelta = record.downloadedBytes - lastSpeedSampleBytes;
            record.downloadSpeedBytesPerSecond =
                (byteDelta * 1000 / elapsed.inMilliseconds).round();
            lastSpeedSampleBytes = record.downloadedBytes;
            lastSpeedSampleTime = now;
          }
          unawaited(_persistDownloadQueue());
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
        record.downloadSpeedBytesPerSecond = 0;
        await _persistDownloadQueue();
        notifyListeners();

        if (expectedSize != null && finalLength != expectedSize) {
          if (!retriedCleanDownload &&
              record.sourceKind == DownloadSourceKind.githubRelease) {
            retriedCleanDownload = true;
            if (destination.existsSync()) {
              await destination.delete();
            }
            record.downloadedBytes = baselineDownloaded;
            await _persistDownloadQueue();
            notifyListeners();
            continue;
          }
          throw StateError(
            'Unexpected file size for ${file.relativePath}: '
            '${formatBytes(finalLength)} downloaded, expected ${formatBytes(expectedSize)}.',
          );
        }
        if (file.sha256 != null) {
          final digest = await _computeFileSha256(destination);
          if (digest != file.sha256) {
            throw StateError('Checksum mismatch for ${file.relativePath}.');
          }
        }
        return;
      } finally {
        monitor.cancel();
      }
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
    DateTime? installedAt,
    DateTime? metadataUpdatedAt,
  }) async {
    final metadataFile = File(
      p.join(modelDirectory.path, _installMetadataFileName),
    );
    final now = DateTime.now();
    final payload = <String, Object?>{
      'sourceLabel': sourceLabel,
      'installedAt': (installedAt ?? now).toIso8601String(),
      'metadataUpdatedAt': (metadataUpdatedAt ?? now).toIso8601String(),
      'manifest': manifest.toJson(),
    };
    await metadataFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  Future<LocalModelManifest> _latestManifestForInstalledModel(
    InstalledModel model,
  ) async {
    final release = _firstWhereOrNull(
      githubReleases,
      (item) => item.tagName == model.manifest.packaging.releaseTag,
    );
    if (release != null) {
      final releaseManifest = await apiClient.fetchReleaseManifest(release);
      if (releaseManifest != null) {
        return releaseManifest;
      }
    }
    final registryManifest = _firstWhereOrNull(
      registry.manifests,
      (item) => item.id == model.manifest.id,
    );
    return registryManifest ?? model.manifest;
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
      'text-to-image' => RuntimeAdapter.mflux,
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
      'text-to-image' => const <ModelTask>[ModelTask.imageGeneration],
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

(String, String) _parseGitHubRepoPath(String value) {
  var normalized = value.trim();
  normalized = normalized.replaceFirst(RegExp(r'^https://github\.com/'), '');
  normalized = normalized.replaceFirst(RegExp(r'^git@github\.com:'), '');
  normalized = normalized.replaceFirst(RegExp(r'\.git$'), '');
  final parts = normalized.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.length < 2) {
    throw FormatException('Use GitHub repo as owner/name.');
  }
  return (parts[0], parts[1]);
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

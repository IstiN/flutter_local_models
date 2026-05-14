import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:local_models_core/local_models_core.dart';
import 'package:path/path.dart' as p;

import 'model_store.dart';

enum DownloadSourceKind { huggingFace, githubRelease }

String downloadSourceKindToString(DownloadSourceKind value) {
  switch (value) {
    case DownloadSourceKind.huggingFace:
      return 'huggingFace';
    case DownloadSourceKind.githubRelease:
      return 'githubRelease';
  }
}

DownloadSourceKind downloadSourceKindFromString(String value) {
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

String? _stripGithubDigestSha256(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  return value.startsWith('sha256:') ? value.substring(7) : value;
}

Future<List<RemoteFileDescriptor>> fetchGitHubReleaseFileDescriptors({
  required String owner,
  required String repository,
  required String releaseTag,
  String? githubToken,
}) async {
  final client = HttpClient();
  try {
    final uri = Uri.https(
      'api.github.com',
      '/repos/$owner/$repository/releases/tags/${Uri.encodeComponent(releaseTag)}',
    );
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'flutter_local_models_sdk/0.1');
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final token = githubToken?.trim();
    if (token != null && token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'GitHub release API ${response.statusCode} for $releaseTag: '
        '${body.length > 500 ? '${body.substring(0, 500)}…' : body}',
        uri: uri,
      );
    }
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final assets = (decoded['assets'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<String, dynamic>>();
    return assets
        .map(
          (asset) => RemoteFileDescriptor(
            relativePath: asset['name'] as String,
            downloadUri: Uri.parse(asset['browser_download_url'] as String),
            sizeBytes: (asset['size'] as num?)?.toInt(),
            sha256: _stripGithubDigestSha256(asset['digest'] as String?),
          ),
        )
        .toList(growable: false);
  } finally {
    client.close(force: true);
  }
}

Future<void> _concatenateFilesToDestination(List<File> parts, File destination) async {
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

Future<InstalledModel> installGitHubReleaseFromStageDirectory({
  required LocalModelStore store,
  required Directory stageDirectory,
  required LocalModelManifest baseManifest,
  required String sourceLabel,
}) async {
  final manifestFile = File(p.join(stageDirectory.path, 'manifest.source.yaml'));
  var manifest = baseManifest;
  if (manifestFile.existsSync()) {
    manifest = LocalModelManifest.fromYaml(await manifestFile.readAsString());
  }

  final metadataFile = File(p.join(stageDirectory.path, 'release_metadata.json'));
  if (!metadataFile.existsSync()) {
    throw StateError('Missing release_metadata.json in ${stageDirectory.path}');
  }
  final metadata =
      jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
  final partNames = ((metadata['parts'] as List<dynamic>? ?? const <dynamic>[])
          .cast<Map<String, dynamic>>())
      .map((part) => part['file_name'] as String)
      .toList(growable: false);
  final archiveName = metadata['archive_name'] as String;
  final archivePath = p.join(stageDirectory.path, archiveName);

  await _concatenateFilesToDestination(
    partNames.map((name) => File(p.join(stageDirectory.path, name))).toList(),
    File(archivePath),
  );

  final installDir = Directory(
    p.join(store.paths.modelsDirectory.path, manifest.id),
  );
  if (installDir.existsSync()) {
    await installDir.delete(recursive: true);
  }

  await store.paths.modelsDirectory.create(recursive: true);

  final result = await Process.run('tar', <String>[
    '-xf',
    archivePath,
    '-C',
    store.paths.modelsDirectory.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError(
      'Failed to extract release archive: ${result.stderr}',
    );
  }

  await store.writeInstallMetadata(
    installDir,
    manifest,
    sourceLabel: sourceLabel,
  );
  return InstalledModel(
    manifest: manifest,
    directory: installDir,
    sourceLabel: sourceLabel,
    installedAt: DateTime.now(),
    sizeBytes: await directorySizeBytes(installDir),
  );
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
    required this.manifest,
  });

  final String id;
  final String title;
  final DownloadSourceKind sourceKind;
  final String modelId;
  final String sourceLabel;
  final Directory stageDirectory;
  final List<RemoteFileDescriptor> files;
  final LocalModelManifest manifest;

  DownloadTaskStatus status = DownloadTaskStatus.queued;
  int downloadedBytes = 0;
  int totalBytes = 0;
  int downloadSpeedBytesPerSecond = 0;
  String? errorMessage;
  String? installedPath;
  bool pauseRequested = false;
  bool cancelRequested = false;

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

  factory DownloadTaskRecord.fromJsonMap(Map<String, Object?> map) {
    return DownloadTaskRecord(
        id: map['id'] as String,
        title: map['title'] as String,
        sourceKind: downloadSourceKindFromString(map['sourceKind'] as String),
        modelId: map['modelId'] as String,
        sourceLabel: map['sourceLabel'] as String? ?? 'Unknown',
        stageDirectory: Directory(map['stageDirectory'] as String),
        files: List<Map<String, Object?>>.from(
          map['files'] as List,
        ).map(RemoteFileDescriptor.fromJsonMap).toList(growable: false),
        manifest: LocalModelManifest.fromJsonMap(
          Map<String, Object?>.from(map['manifest'] as Map),
        ),
      )
      ..status = DownloadTaskStatus.paused
      ..downloadedBytes = (map['downloadedBytes'] as num?)?.toInt() ?? 0
      ..totalBytes = (map['totalBytes'] as num?)?.toInt() ?? 0
      ..installedPath = map['installedPath'] as String?
      ..errorMessage = map['errorMessage'] as String?;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'sourceKind': downloadSourceKindToString(sourceKind),
    'modelId': modelId,
    'sourceLabel': sourceLabel,
    'stageDirectory': stageDirectory.path,
    'files': files.map((file) => file.toJson()).toList(),
    'manifest': manifest.toJson(),
    'status': status.name,
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    if (installedPath != null) 'installedPath': installedPath,
    if (errorMessage != null) 'errorMessage': errorMessage,
  };
}

typedef DownloadTaskChanged = void Function(DownloadTaskRecord record);

class LocalModelDownloadManager {
  LocalModelDownloadManager({
    required this.store,
    this.maxRetries = 5,
    this.onTaskChanged,
    String? hfToken,
    String? githubToken,
  }) : hfToken = hfToken ?? '',
       githubToken = githubToken ?? '';

  final LocalModelStore store;
  final int maxRetries;
  final DownloadTaskChanged? onTaskChanged;
  String hfToken;
  String githubToken;

  Future<DownloadTaskRecord> startDownload({
    required LocalModelManifest manifest,
    required DownloadSourceKind sourceKind,
    required String sourceLabel,
    required List<RemoteFileDescriptor> files,
  }) async {
    await store.paths.ensureCreated();
    final stageDir = Directory(
      p.join(
        store.paths.downloadsDirectory.path,
        '${downloadSourceKindToString(sourceKind)}-${manifest.id}-${DateTime.now().millisecondsSinceEpoch}',
        manifest.id,
      ),
    );
    final record = DownloadTaskRecord(
      id: '${downloadSourceKindToString(sourceKind)}-${manifest.id}-${DateTime.now().microsecondsSinceEpoch}',
      title: manifest.displayName,
      sourceKind: sourceKind,
      modelId: manifest.id,
      sourceLabel: sourceLabel,
      stageDirectory: stageDir,
      files: files,
      manifest: manifest,
    );
    unawaited(run(record));
    return record;
  }

  Future<InstalledModel> downloadAndInstallFromGitHubRelease({
    required LocalModelManifest manifest,
    String githubOwner = 'IstiN',
    String githubRepository = 'flutter_local_models',
    String sourceLabel = 'GitHub Release',
  }) async {
    final files = await fetchGitHubReleaseFileDescriptors(
      owner: githubOwner,
      repository: githubRepository,
      releaseTag: manifest.packaging.releaseTag,
      githubToken: githubToken,
    );
    if (files.isEmpty) {
      throw StateError(
        'No assets in GitHub release ${manifest.packaging.releaseTag}',
      );
    }
    await store.paths.ensureCreated();
    final stageDir = Directory(
      p.join(
        store.paths.downloadsDirectory.path,
        'gh-${manifest.packaging.releaseTag}-${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
    final record = DownloadTaskRecord(
      id: 'gh-${manifest.id}-${DateTime.now().microsecondsSinceEpoch}',
      title: manifest.displayName,
      sourceKind: DownloadSourceKind.githubRelease,
      modelId: manifest.id,
      sourceLabel: sourceLabel,
      stageDirectory: stageDir,
      files: files,
      manifest: manifest,
    );
    return run(
      record,
      customInstall: (task) => installGitHubReleaseFromStageDirectory(
        store: store,
        stageDirectory: task.stageDirectory,
        baseManifest: task.manifest,
        sourceLabel: task.sourceLabel,
      ),
    );
  }

  Future<InstalledModel> run(
    DownloadTaskRecord record, {
    Future<InstalledModel> Function(DownloadTaskRecord record)? customInstall,
  }) async {
    await store.paths.ensureCreated();
    record.status = DownloadTaskStatus.running;
    record.totalBytes = record.files.fold<int>(
      0,
      (sum, file) => sum + (file.sizeBytes ?? 0),
    );
    await record.stageDirectory.create(recursive: true);
    onTaskChanged?.call(record);

    var attempt = 0;
    while (true) {
      try {
        for (final file in record.files) {
          await _downloadFile(record, file);
        }
        record.status = DownloadTaskStatus.installing;
        onTaskChanged?.call(record);
        final install =
            customInstall ?? _installDownloadedModel;
        final installed = await install(record);
        record.status = DownloadTaskStatus.completed;
        record.installedPath = installed.directory.path;
        if (record.stageDirectory.existsSync()) {
          await record.stageDirectory.delete(recursive: true);
        }
        onTaskChanged?.call(record);
        return installed;
      } catch (error) {
        if (!_isRetryableDownloadError(error) || attempt >= maxRetries) {
          record.status = DownloadTaskStatus.failed;
          record.errorMessage = '$error';
          onTaskChanged?.call(record);
          rethrow;
        }
        attempt += 1;
        record.errorMessage = 'Retry $attempt/$maxRetries after: $error';
        onTaskChanged?.call(record);
        await Future<void>.delayed(
          Duration(seconds: (1 << (attempt - 1)).clamp(1, 30)),
        );
      }
    }
  }

  void pause(DownloadTaskRecord record) {
    record.pauseRequested = true;
    onTaskChanged?.call(record);
  }

  void cancel(DownloadTaskRecord record) {
    record.cancelRequested = true;
    onTaskChanged?.call(record);
  }

  Future<InstalledModel> _installDownloadedModel(
    DownloadTaskRecord record,
  ) async {
    final installDir = Directory(
      p.join(store.paths.modelsDirectory.path, record.manifest.id),
    );
    if (installDir.existsSync()) {
      await installDir.delete(recursive: true);
    }
    await record.stageDirectory.rename(installDir.path);
    await store.writeInstallMetadata(
      installDir,
      record.manifest,
      sourceLabel: record.sourceLabel,
    );
    return InstalledModel(
      manifest: record.manifest,
      directory: installDir,
      sourceLabel: record.sourceLabel,
      installedAt: DateTime.now(),
      sizeBytes: await directorySizeBytes(installDir),
    );
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

    while (true) {
      if (record.cancelRequested) {
        throw const DownloadCanceledException();
      }
      if (record.pauseRequested) {
        record.status = DownloadTaskStatus.paused;
        throw const DownloadPausedException();
      }

      final alreadyWritten = destination.existsSync()
          ? await destination.length()
          : 0;
      if (expectedSize != null && alreadyWritten == expectedSize) {
        await _verifyChecksumIfPresent(destination, file);
        return;
      }

      final baselineDownloaded = record.downloadedBytes - alreadyWritten;
      final args = <String>[
        '-L',
        '--fail',
        '--silent',
        '--show-error',
        '--http1.1',
        ..._curlHeaderArgs(<String, String>{
          HttpHeaders.userAgentHeader: 'flutter_local_models_sdk/0.1',
          HttpHeaders.acceptHeader: 'application/octet-stream',
          if (record.sourceKind == DownloadSourceKind.huggingFace &&
              hfToken.trim().isNotEmpty)
            HttpHeaders.authorizationHeader: 'Bearer ${hfToken.trim()}',
          if (record.sourceKind == DownloadSourceKind.githubRelease &&
              githubToken.trim().isNotEmpty)
            HttpHeaders.authorizationHeader: 'Bearer ${githubToken.trim()}',
        }),
        if (alreadyWritten > 0) ...<String>['-C', '-'],
        '-o',
        destination.path,
        file.downloadUri.toString(),
      ];

      final result = await Process.run(_curlExecutable, args);
      if (result.exitCode != 0) {
        final stderr = (result.stderr as String).trim();
        throw HttpException(
          'Download failed for ${file.relativePath}: '
          '${stderr.isEmpty ? 'curl exited with code ${result.exitCode}' : stderr}',
        );
      }
      final finalLength = destination.existsSync()
          ? await destination.length()
          : 0;
      record.downloadedBytes = baselineDownloaded + finalLength;
      record.downloadSpeedBytesPerSecond = 0;
      onTaskChanged?.call(record);

      if (expectedSize != null && finalLength != expectedSize) {
        throw StateError(
          'Unexpected file size for ${file.relativePath}: '
          '${formatBytes(finalLength)} downloaded, expected ${formatBytes(expectedSize)}.',
        );
      }
      await _verifyChecksumIfPresent(destination, file);
      return;
    }
  }

  Future<void> _verifyChecksumIfPresent(
    File destination,
    RemoteFileDescriptor file,
  ) async {
    final expected = _stripShaPrefix(file.sha256);
    if (expected == null) {
      return;
    }
    final digest = await sha256.bind(destination.openRead()).first;
    if (digest.toString() != expected) {
      throw StateError('Checksum mismatch for ${file.relativePath}.');
    }
  }
}

class DownloadPausedException implements Exception {
  const DownloadPausedException();
}

class DownloadCanceledException implements Exception {
  const DownloadCanceledException();
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
    return error.message.toLowerCase().contains('unexpected file size');
  }
  return false;
}

String? _stripShaPrefix(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  return value.startsWith('sha256:') ? value.substring(7) : value;
}

List<String> _curlHeaderArgs(Map<String, String> headers) {
  final args = <String>[];
  headers.forEach((key, value) {
    args.add('-H');
    args.add('$key: $value');
  });
  return args;
}

String get _curlExecutable =>
    File('/usr/bin/curl').existsSync() ? '/usr/bin/curl' : 'curl';

library;

import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

enum RuntimeAdapter { mlxLm, mlxVlm, mlxAudio, mflux, nativeBridge }

enum ModelTask {
  chat,
  vision,
  code,
  audioInput,
  audioOutput,
  speechToText,
  textToSpeech,
  imageGeneration,
}

enum LocalChatRole { system, user, assistant, tool }

enum LocalAttachmentType { image, audio, file }

enum LocalToolChoiceMode { auto, none, required, named }

String localChatRoleToString(LocalChatRole value) {
  switch (value) {
    case LocalChatRole.system:
      return 'system';
    case LocalChatRole.user:
      return 'user';
    case LocalChatRole.assistant:
      return 'assistant';
    case LocalChatRole.tool:
      return 'tool';
  }
}

LocalChatRole localChatRoleFromString(String value) {
  switch (value) {
    case 'system':
      return LocalChatRole.system;
    case 'user':
      return LocalChatRole.user;
    case 'assistant':
      return LocalChatRole.assistant;
    case 'tool':
      return LocalChatRole.tool;
    default:
      throw FormatException('Unsupported chat role: $value');
  }
}

String localAttachmentTypeToString(LocalAttachmentType value) {
  switch (value) {
    case LocalAttachmentType.image:
      return 'image';
    case LocalAttachmentType.audio:
      return 'audio';
    case LocalAttachmentType.file:
      return 'file';
  }
}

LocalAttachmentType localAttachmentTypeFromString(String value) {
  switch (value) {
    case 'image':
      return LocalAttachmentType.image;
    case 'audio':
      return LocalAttachmentType.audio;
    case 'file':
      return LocalAttachmentType.file;
    default:
      throw FormatException('Unsupported attachment type: $value');
  }
}

String localToolChoiceModeToString(LocalToolChoiceMode value) {
  switch (value) {
    case LocalToolChoiceMode.auto:
      return 'auto';
    case LocalToolChoiceMode.none:
      return 'none';
    case LocalToolChoiceMode.required:
      return 'required';
    case LocalToolChoiceMode.named:
      return 'named';
  }
}

LocalToolChoiceMode localToolChoiceModeFromString(String value) {
  switch (value) {
    case 'auto':
      return LocalToolChoiceMode.auto;
    case 'none':
      return LocalToolChoiceMode.none;
    case 'required':
      return LocalToolChoiceMode.required;
    case 'named':
      return LocalToolChoiceMode.named;
    default:
      throw FormatException('Unsupported tool choice mode: $value');
  }
}

RuntimeAdapter _runtimeAdapterFromString(String value) {
  switch (value) {
    case 'mlx_lm':
      return RuntimeAdapter.mlxLm;
    case 'mlx_vlm':
      return RuntimeAdapter.mlxVlm;
    case 'mlx_audio':
      return RuntimeAdapter.mlxAudio;
    case 'mflux':
      return RuntimeAdapter.mflux;
    case 'native_bridge':
      return RuntimeAdapter.nativeBridge;
    default:
      throw FormatException('Unsupported runtime adapter: $value');
  }
}

String _runtimeAdapterToString(RuntimeAdapter value) {
  switch (value) {
    case RuntimeAdapter.mlxLm:
      return 'mlx_lm';
    case RuntimeAdapter.mlxVlm:
      return 'mlx_vlm';
    case RuntimeAdapter.mlxAudio:
      return 'mlx_audio';
    case RuntimeAdapter.mflux:
      return 'mflux';
    case RuntimeAdapter.nativeBridge:
      return 'native_bridge';
  }
}

ModelTask _modelTaskFromString(String value) {
  switch (value) {
    case 'chat':
      return ModelTask.chat;
    case 'vision':
      return ModelTask.vision;
    case 'code':
      return ModelTask.code;
    case 'audio_input':
      return ModelTask.audioInput;
    case 'audio_output':
      return ModelTask.audioOutput;
    case 'speech_to_text':
      return ModelTask.speechToText;
    case 'text_to_speech':
      return ModelTask.textToSpeech;
    case 'image_generation':
      return ModelTask.imageGeneration;
    default:
      throw FormatException('Unsupported model task: $value');
  }
}

String modelTaskToString(ModelTask value) {
  switch (value) {
    case ModelTask.chat:
      return 'chat';
    case ModelTask.vision:
      return 'vision';
    case ModelTask.code:
      return 'code';
    case ModelTask.audioInput:
      return 'audio_input';
    case ModelTask.audioOutput:
      return 'audio_output';
    case ModelTask.speechToText:
      return 'speech_to_text';
    case ModelTask.textToSpeech:
      return 'text_to_speech';
    case ModelTask.imageGeneration:
      return 'image_generation';
  }
}

@immutable
class ModelSource {
  const ModelSource({
    required this.provider,
    required this.repo,
    required this.revision,
    required this.license,
  });

  final String provider;
  final String repo;
  final String revision;
  final String license;

  factory ModelSource.fromMap(Map<Object?, Object?> map) {
    return ModelSource(
      provider: map['provider'] as String,
      repo: map['repo'] as String,
      revision: map['revision'] as String? ?? 'main',
      license: map['license'] as String? ?? 'unknown',
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider,
    'repo': repo,
    'revision': revision,
    'license': license,
  };
}

@immutable
class PackagingSpec {
  const PackagingSpec({
    required this.releaseTag,
    required this.archiveName,
    required this.chunkSizeBytes,
    required this.assetPrefix,
  });

  final String releaseTag;
  final String archiveName;
  final int chunkSizeBytes;
  final String assetPrefix;

  factory PackagingSpec.fromMap(Map<Object?, Object?> map) {
    return PackagingSpec(
      releaseTag: map['release_tag'] as String? ?? map['releaseTag'] as String,
      archiveName:
          map['archive_name'] as String? ?? map['archiveName'] as String,
      chunkSizeBytes:
          ((map['chunk_size_bytes'] as num?) ?? (map['chunkSizeBytes'] as num))
              .toInt(),
      assetPrefix:
          map['asset_prefix'] as String? ?? map['assetPrefix'] as String,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'releaseTag': releaseTag,
    'archiveName': archiveName,
    'chunkSizeBytes': chunkSizeBytes,
    'assetPrefix': assetPrefix,
  };
}

@immutable
class SystemRequirements {
  const SystemRequirements({
    required this.platform,
    required this.minMemoryGb,
    required this.recommendedMemoryGb,
    required this.notes,
  });

  final String platform;
  final int minMemoryGb;
  final int recommendedMemoryGb;
  final List<String> notes;

  factory SystemRequirements.fromMap(Map<Object?, Object?> map) {
    return SystemRequirements(
      platform: map['platform'] as String,
      minMemoryGb:
          ((map['min_memory_gb'] as num?) ?? (map['minMemoryGb'] as num))
              .toInt(),
      recommendedMemoryGb:
          ((map['recommended_memory_gb'] as num?) ??
                  (map['recommendedMemoryGb'] as num))
              .toInt(),
      notes: List<String>.from(map['notes'] as List? ?? const <String>[]),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'platform': platform,
    'minMemoryGb': minMemoryGb,
    'recommendedMemoryGb': recommendedMemoryGb,
    'notes': notes,
  };
}

@immutable
class CapabilitySpec {
  const CapabilitySpec({
    required this.audioInput,
    required this.audioOutput,
    required this.toolCalling,
  });

  final bool audioInput;
  final bool audioOutput;
  final bool toolCalling;

  factory CapabilitySpec.fromMap(Map<Object?, Object?> map) {
    return CapabilitySpec(
      audioInput:
          map['audio_input'] as bool? ?? map['audioInput'] as bool? ?? false,
      audioOutput:
          map['audio_output'] as bool? ?? map['audioOutput'] as bool? ?? false,
      toolCalling:
          map['tool_calling'] as bool? ?? map['toolCalling'] as bool? ?? false,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'audioInput': audioInput,
    'audioOutput': audioOutput,
    'toolCalling': toolCalling,
  };
}

@immutable
class LocalModelManifest {
  const LocalModelManifest({
    required this.id,
    required this.displayName,
    required this.description,
    required this.runtimeAdapter,
    required this.tasks,
    required this.source,
    required this.packaging,
    required this.requirements,
    required this.capabilities,
  });

  final String id;
  final String displayName;
  final String description;
  final RuntimeAdapter runtimeAdapter;
  final List<ModelTask> tasks;
  final ModelSource source;
  final PackagingSpec packaging;
  final SystemRequirements requirements;
  final CapabilitySpec capabilities;

  factory LocalModelManifest.fromYaml(String yaml) {
    final dynamic data = loadYaml(yaml);
    final map = jsonDecode(jsonEncode(data)) as Map<String, Object?>;
    return LocalModelManifest.fromJsonMap(map);
  }

  factory LocalModelManifest.fromJsonMap(Map<String, Object?> map) {
    return LocalModelManifest(
      id: map['id'] as String,
      displayName:
          map['display_name'] as String? ?? map['displayName'] as String,
      description: map['description'] as String,
      runtimeAdapter: _runtimeAdapterFromString(
        map['runtime_adapter'] as String? ?? map['runtimeAdapter'] as String,
      ),
      tasks: List<String>.from(
        map['tasks'] as List,
      ).map(_modelTaskFromString).toList(growable: false),
      source: ModelSource.fromMap(
        Map<Object?, Object?>.from(map['source'] as Map),
      ),
      packaging: PackagingSpec.fromMap(
        Map<Object?, Object?>.from(map['packaging'] as Map),
      ),
      requirements: SystemRequirements.fromMap(
        Map<Object?, Object?>.from(map['requirements'] as Map),
      ),
      capabilities: CapabilitySpec.fromMap(
        Map<Object?, Object?>.from(map['capabilities'] as Map),
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'displayName': displayName,
    'description': description,
    'runtimeAdapter': _runtimeAdapterToString(runtimeAdapter),
    'tasks': tasks.map(modelTaskToString).toList(growable: false),
    'source': source.toJson(),
    'packaging': packaging.toJson(),
    'requirements': requirements.toJson(),
    'capabilities': capabilities.toJson(),
  };
}

@immutable
class NativeRuntimeSummary {
  const NativeRuntimeSummary({
    required this.bridgeVersion,
    required this.platform,
    required this.metalAvailable,
    required this.mlxFocused,
    required this.ffiEnabled,
    this.errorMessage,
  });

  final String bridgeVersion;
  final String platform;
  final bool metalAvailable;
  final bool mlxFocused;
  final bool ffiEnabled;
  final String? errorMessage;

  bool get hasError => errorMessage != null && errorMessage!.isNotEmpty;

  factory NativeRuntimeSummary.fromJsonMap(Map<String, Object?> map) {
    return NativeRuntimeSummary(
      bridgeVersion: map['bridgeVersion'] as String? ?? 'unknown',
      platform: map['platform'] as String? ?? 'unknown',
      metalAvailable: map['metalAvailable'] as bool? ?? false,
      mlxFocused: map['mlxFocused'] as bool? ?? true,
      ffiEnabled: map['ffiEnabled'] as bool? ?? true,
      errorMessage: map['errorMessage'] as String?,
    );
  }

  factory NativeRuntimeSummary.error(String message) {
    return NativeRuntimeSummary(
      bridgeVersion: 'unavailable',
      platform: Platform.operatingSystem,
      metalAvailable: false,
      mlxFocused: true,
      ffiEnabled: false,
      errorMessage: message,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'bridgeVersion': bridgeVersion,
    'platform': platform,
    'metalAvailable': metalAvailable,
    'mlxFocused': mlxFocused,
    'ffiEnabled': ffiEnabled,
    'errorMessage': errorMessage,
  };
}

@immutable
class LocalMessageAttachment {
  const LocalMessageAttachment({
    required this.type,
    required this.uri,
    this.mimeType,
    this.name,
  });

  final LocalAttachmentType type;
  final Uri uri;
  final String? mimeType;
  final String? name;

  factory LocalMessageAttachment.file({
    required LocalAttachmentType type,
    required String path,
    String? mimeType,
    String? name,
  }) {
    return LocalMessageAttachment(
      type: type,
      uri: Uri.file(path),
      mimeType: mimeType,
      name: name ?? p.basename(path),
    );
  }

  factory LocalMessageAttachment.fromJsonMap(Map<String, Object?> map) {
    return LocalMessageAttachment(
      type: localAttachmentTypeFromString(map['type'] as String),
      uri: Uri.parse(map['uri'] as String),
      mimeType: map['mimeType'] as String?,
      name: map['name'] as String?,
    );
  }

  String? get filePath => uri.isScheme('file') ? uri.toFilePath() : null;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': localAttachmentTypeToString(type),
    'uri': uri.toString(),
    if (mimeType != null) 'mimeType': mimeType,
    if (name != null) 'name': name,
  };
}

@immutable
class LocalTool {
  const LocalTool({
    required this.name,
    required this.description,
    this.parametersJsonSchema = const <String, Object?>{},
    this.metadata = const <String, Object?>{},
  });

  final String name;
  final String description;
  final Map<String, Object?> parametersJsonSchema;
  final Map<String, Object?> metadata;

  const factory LocalTool.function({
    required String name,
    required String description,
    Map<String, Object?> parametersJsonSchema,
    Map<String, Object?> metadata,
  }) = LocalTool;

  factory LocalTool.fromJsonMap(Map<String, Object?> map) {
    return LocalTool(
      name: map['name'] as String,
      description: map['description'] as String? ?? '',
      parametersJsonSchema: Map<String, Object?>.from(
        map['parametersJsonSchema'] as Map? ??
            map['parameters'] as Map? ??
            const <String, Object?>{},
      ),
      metadata: Map<String, Object?>.from(
        map['metadata'] as Map? ?? const <String, Object?>{},
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'description': description,
    'parametersJsonSchema': parametersJsonSchema,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  Map<String, Object?> toOpenAIJson() => <String, Object?>{
    'type': 'function',
    'function': <String, Object?>{
      'name': name,
      'description': description,
      'parameters': parametersJsonSchema.isEmpty
          ? const <String, Object?>{'type': 'object', 'properties': {}}
          : parametersJsonSchema,
    },
  };
}

@immutable
class LocalToolChoice {
  const LocalToolChoice({required this.mode, this.name});

  const LocalToolChoice.auto() : this(mode: LocalToolChoiceMode.auto);
  const LocalToolChoice.none() : this(mode: LocalToolChoiceMode.none);
  const LocalToolChoice.required() : this(mode: LocalToolChoiceMode.required);
  const LocalToolChoice.named(String name)
    : this(mode: LocalToolChoiceMode.named, name: name);

  final LocalToolChoiceMode mode;
  final String? name;

  factory LocalToolChoice.fromJsonMap(Map<String, Object?> map) {
    return LocalToolChoice(
      mode: localToolChoiceModeFromString(map['mode'] as String),
      name: map['name'] as String?,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'mode': localToolChoiceModeToString(mode),
    if (name != null) 'name': name,
  };

  Object toOpenAIJson() {
    switch (mode) {
      case LocalToolChoiceMode.auto:
        return 'auto';
      case LocalToolChoiceMode.none:
        return 'none';
      case LocalToolChoiceMode.required:
        return 'required';
      case LocalToolChoiceMode.named:
        return <String, Object?>{
          'type': 'function',
          'function': <String, Object?>{'name': name},
        };
    }
  }
}

@immutable
class LocalToolCall {
  const LocalToolCall({
    required this.id,
    required this.name,
    this.arguments = const <String, Object?>{},
    this.rawArguments,
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final String name;
  final Map<String, Object?> arguments;
  final String? rawArguments;
  final Map<String, Object?> metadata;

  factory LocalToolCall.fromJsonMap(Map<String, Object?> map) {
    return LocalToolCall(
      id: map['id'] as String,
      name: map['name'] as String,
      arguments: Map<String, Object?>.from(
        map['arguments'] as Map? ?? const <String, Object?>{},
      ),
      rawArguments: map['rawArguments'] as String?,
      metadata: Map<String, Object?>.from(
        map['metadata'] as Map? ?? const <String, Object?>{},
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'arguments': arguments,
    if (rawArguments != null) 'rawArguments': rawArguments,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  Map<String, Object?> toOpenAIJson() => <String, Object?>{
    'id': id,
    'type': 'function',
    'function': <String, Object?>{
      'name': name,
      'arguments': rawArguments ?? jsonEncode(arguments),
    },
  };
}

@immutable
class LocalChatMessage {
  const LocalChatMessage({
    required this.role,
    required this.content,
    this.attachments = const <LocalMessageAttachment>[],
    this.toolCalls = const <LocalToolCall>[],
    this.toolCallId,
    this.metadata = const <String, Object?>{},
  });

  const LocalChatMessage.system(
    String content, {
    List<LocalMessageAttachment> attachments = const <LocalMessageAttachment>[],
    List<LocalToolCall> toolCalls = const <LocalToolCall>[],
    String? toolCallId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : this(
         role: LocalChatRole.system,
         content: content,
         attachments: attachments,
         toolCalls: toolCalls,
         toolCallId: toolCallId,
         metadata: metadata,
       );

  const LocalChatMessage.user(
    String content, {
    List<LocalMessageAttachment> attachments = const <LocalMessageAttachment>[],
    List<LocalToolCall> toolCalls = const <LocalToolCall>[],
    String? toolCallId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : this(
         role: LocalChatRole.user,
         content: content,
         attachments: attachments,
         toolCalls: toolCalls,
         toolCallId: toolCallId,
         metadata: metadata,
       );

  const LocalChatMessage.assistant(
    String content, {
    List<LocalMessageAttachment> attachments = const <LocalMessageAttachment>[],
    List<LocalToolCall> toolCalls = const <LocalToolCall>[],
    String? toolCallId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : this(
         role: LocalChatRole.assistant,
         content: content,
         attachments: attachments,
         toolCalls: toolCalls,
         toolCallId: toolCallId,
         metadata: metadata,
       );

  const LocalChatMessage.toolResult({
    required String toolCallId,
    required String content,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : this(
         role: LocalChatRole.tool,
         content: content,
         toolCallId: toolCallId,
         metadata: metadata,
       );

  final LocalChatRole role;
  final String content;
  final List<LocalMessageAttachment> attachments;
  final List<LocalToolCall> toolCalls;
  final String? toolCallId;
  final Map<String, Object?> metadata;

  factory LocalChatMessage.fromJsonMap(Map<String, Object?> map) {
    return LocalChatMessage(
      role: localChatRoleFromString(map['role'] as String),
      content: map['content'] as String? ?? '',
      attachments: List<Map<String, Object?>>.from(
        map['attachments'] as List? ?? const <Map<String, Object?>>[],
      ).map(LocalMessageAttachment.fromJsonMap).toList(growable: false),
      toolCalls: List<Map<String, Object?>>.from(
        map['toolCalls'] as List? ?? const <Map<String, Object?>>[],
      ).map(LocalToolCall.fromJsonMap).toList(growable: false),
      toolCallId: map['toolCallId'] as String?,
      metadata: Map<String, Object?>.from(
        map['metadata'] as Map? ?? const <String, Object?>{},
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'role': localChatRoleToString(role),
    'content': content,
    'attachments': attachments.map((item) => item.toJson()).toList(),
    if (toolCalls.isNotEmpty)
      'toolCalls': toolCalls.map((item) => item.toJson()).toList(),
    if (toolCallId != null) 'toolCallId': toolCallId,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };
}

@immutable
class LocalChatParams {
  const LocalChatParams({
    this.modelId,
    this.maxTokens = 256,
    this.temperature,
    this.topP,
    this.stop = const <String>[],
    this.tools = const <LocalTool>[],
    this.toolChoice,
    this.extra = const <String, Object?>{},
  });

  final String? modelId;
  final int maxTokens;
  final double? temperature;
  final double? topP;
  final List<String> stop;
  final List<LocalTool> tools;
  final LocalToolChoice? toolChoice;
  final Map<String, Object?> extra;

  factory LocalChatParams.fromJsonMap(Map<String, Object?> map) {
    return LocalChatParams(
      modelId: map['modelId'] as String?,
      maxTokens: (map['maxTokens'] as num?)?.toInt() ?? 256,
      temperature: (map['temperature'] as num?)?.toDouble(),
      topP: (map['topP'] as num?)?.toDouble(),
      stop: List<String>.from(map['stop'] as List? ?? const <String>[]),
      tools: List<Map<String, Object?>>.from(
        map['tools'] as List? ?? const <Map<String, Object?>>[],
      ).map(LocalTool.fromJsonMap).toList(growable: false),
      toolChoice: map['toolChoice'] == null
          ? null
          : LocalToolChoice.fromJsonMap(
              Map<String, Object?>.from(map['toolChoice'] as Map),
            ),
      extra: Map<String, Object?>.from(
        map['extra'] as Map? ?? const <String, Object?>{},
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    if (modelId != null) 'modelId': modelId,
    'maxTokens': maxTokens,
    if (temperature != null) 'temperature': temperature,
    if (topP != null) 'topP': topP,
    if (stop.isNotEmpty) 'stop': stop,
    if (tools.isNotEmpty) 'tools': tools.map((item) => item.toJson()).toList(),
    if (toolChoice != null) 'toolChoice': toolChoice!.toJson(),
    if (extra.isNotEmpty) 'extra': extra,
  };
}

@immutable
class LocalChatDelta {
  const LocalChatDelta({
    required this.content,
    this.done = false,
    this.toolCalls = const <LocalToolCall>[],
    this.finishReason,
    this.metadata = const <String, Object?>{},
  });

  final String content;
  final bool done;
  final List<LocalToolCall> toolCalls;
  final String? finishReason;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => <String, Object?>{
    'content': content,
    'done': done,
    if (toolCalls.isNotEmpty)
      'toolCalls': toolCalls.map((item) => item.toJson()).toList(),
    if (finishReason != null) 'finishReason': finishReason,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };
}

@immutable
class LocalChatResponse {
  const LocalChatResponse({
    required this.message,
    this.metadata = const <String, Object?>{},
  });

  final LocalChatMessage message;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => <String, Object?>{
    'message': message.toJson(),
    if (metadata.isNotEmpty) 'metadata': metadata,
  };
}

class ModelRegistry {
  ModelRegistry(List<LocalModelManifest> manifests)
    : manifests = List<LocalModelManifest>.unmodifiable(
        [...manifests]..sort((a, b) => a.displayName.compareTo(b.displayName)),
      );

  final List<LocalModelManifest> manifests;

  LocalModelManifest byId(String id) {
    return manifests.firstWhere(
      (manifest) => manifest.id == id,
      orElse: () => throw StateError('No manifest found for id: $id'),
    );
  }

  static Future<ModelRegistry> loadDirectory(String directoryPath) async {
    final directory = Directory(directoryPath);
    if (!directory.existsSync()) {
      throw FileSystemException('Registry directory not found', directoryPath);
    }

    final manifests = <LocalModelManifest>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.yaml')) {
        continue;
      }
      manifests.add(LocalModelManifest.fromYaml(await entity.readAsString()));
    }
    return ModelRegistry(manifests);
  }

  static ModelRegistry fromCatalogJson(String jsonString) {
    final decoded = jsonDecode(jsonString) as List<dynamic>;
    return ModelRegistry(
      decoded
          .cast<Map<String, Object?>>()
          .map(LocalModelManifest.fromJsonMap)
          .toList(growable: false),
    );
  }

  String toCatalogJson() {
    final list = manifests.map((manifest) => manifest.toJson()).toList();
    return const JsonEncoder.withIndent('  ').convert(list);
  }
}

@immutable
class ReleaseChunk {
  const ReleaseChunk({
    required this.fileName,
    required this.index,
    required this.releaseTag,
  });

  final String fileName;
  final int index;
  final String releaseTag;
}

@immutable
class ReleaseBundlePlan {
  const ReleaseBundlePlan({
    required this.releaseTag,
    required this.archiveName,
    required this.chunkSizeBytes,
    required this.sampleChunks,
  });

  final String releaseTag;
  final String archiveName;
  final int chunkSizeBytes;
  final List<ReleaseChunk> sampleChunks;

  factory ReleaseBundlePlan.fromManifest(
    LocalModelManifest manifest, {
    int sampleChunkCount = 3,
  }) {
    final chunks = List<ReleaseChunk>.generate(
      sampleChunkCount,
      (index) => ReleaseChunk(
        fileName:
            '${manifest.packaging.assetPrefix}.part-${index.toString().padLeft(3, '0')}',
        index: index,
        releaseTag: manifest.packaging.releaseTag,
      ),
      growable: false,
    );
    return ReleaseBundlePlan(
      releaseTag: manifest.packaging.releaseTag,
      archiveName: manifest.packaging.archiveName,
      chunkSizeBytes: manifest.packaging.chunkSizeBytes,
      sampleChunks: chunks,
    );
  }
}

String resolveDefaultRegistryPath(String currentDirectory) {
  return p.normalize(p.join(currentDirectory, 'registry', 'models'));
}

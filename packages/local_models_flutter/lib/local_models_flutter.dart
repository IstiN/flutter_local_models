library;

export 'package:local_models_core/local_models_core.dart';

import 'package:local_models_core/local_models_core.dart';

import 'local_models_flutter_platform_interface.dart';

abstract interface class LocalChatRuntime {
  Future<List<LocalModelManifest>> getModels();

  Stream<LocalChatDelta> chatStream({
    required List<LocalChatMessage> messages,
    LocalChatParams params = const LocalChatParams(),
  });
}

class LocalModelsFlutter {
  LocalModelsFlutter({LocalChatRuntime? chatRuntime})
    : _chatRuntime = chatRuntime;

  final LocalChatRuntime? _chatRuntime;

  Future<NativeRuntimeSummary> getRuntimeSummary() {
    return LocalModelsFlutterPlatform.instance.getRuntimeSummary();
  }

  Future<List<LocalModelManifest>> getModels() {
    final runtime = _chatRuntime;
    if (runtime == null) {
      return Future<List<LocalModelManifest>>.error(
        UnsupportedError(
          'No LocalChatRuntime is configured yet. Provide a runtime adapter to list models.',
        ),
      );
    }
    return runtime.getModels();
  }

  Stream<LocalChatDelta> chatStream({
    required List<LocalChatMessage> messages,
    LocalChatParams params = const LocalChatParams(),
  }) {
    final runtime = _chatRuntime;
    if (runtime == null) {
      return Stream<LocalChatDelta>.error(
        UnsupportedError(
          'No LocalChatRuntime is configured yet. Provide a runtime adapter or use a higher-level Studio adapter.',
        ),
      );
    }
    return runtime.chatStream(messages: messages, params: params);
  }

  Stream<LocalChatDelta> chatStreamRequest(LocalChatRequest request) {
    return chatStream(messages: request.messages, params: request.params);
  }

  Future<LocalChatResponse> chat({
    required List<LocalChatMessage> messages,
    LocalChatParams params = const LocalChatParams(),
  }) async {
    final buffer = StringBuffer();
    final metadata = <String, Object?>{};
    final toolCalls = <LocalToolCall>[];
    await for (final delta in chatStream(messages: messages, params: params)) {
      buffer.write(delta.content);
      toolCalls.addAll(delta.toolCalls);
      metadata.addAll(delta.metadata);
      if (delta.finishReason != null) {
        metadata['finishReason'] = delta.finishReason;
      }
    }
    return LocalChatResponse(
      message: LocalChatMessage.assistant(
        buffer.toString(),
        toolCalls: toolCalls,
      ),
      metadata: metadata,
    );
  }

  Future<LocalChatResponse> chatRequest(LocalChatRequest request) {
    return chat(messages: request.messages, params: request.params);
  }
}

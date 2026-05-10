library;

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

  Future<LocalChatResponse> chat({
    required List<LocalChatMessage> messages,
    LocalChatParams params = const LocalChatParams(),
  }) async {
    final buffer = StringBuffer();
    final metadata = <String, Object?>{};
    await for (final delta in chatStream(messages: messages, params: params)) {
      buffer.write(delta.content);
      metadata.addAll(delta.metadata);
    }
    return LocalChatResponse(
      message: LocalChatMessage.assistant(buffer.toString()),
      metadata: metadata,
    );
  }
}

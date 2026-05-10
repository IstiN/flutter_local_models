# local_models_flutter

Flutter SDK surface for local model runtimes. The public API is runtime-agnostic:
your app can plug in an MLX adapter, a native FFI bridge, a daemon, or a mock
runtime for tests without changing chat UI code.

## Core API

```dart
final localModels = LocalModelsFlutter(chatRuntime: myRuntimeAdapter);

final models = await localModels.getModels();
final model = models.first;

final request = LocalChatRequest(
  messages: [
    const LocalChatMessage.system('You are a concise local assistant.'),
    LocalChatMessage.user(
      'What is in this image?',
      attachments: [
        LocalMessageAttachment.file(
          type: LocalAttachmentType.image,
          path: '/Users/me/image.png',
          mimeType: 'image/png',
        ),
      ],
    ),
  ],
  params: LocalChatParams(
    modelId: model.id,
    maxTokens: 256,
    temperature: 0.2,
    tools: const [
      LocalTool.function(
        name: 'get_weather',
        description: 'Get current weather for a city.',
        parametersJsonSchema: {
          'type': 'object',
          'properties': {
            'city': {'type': 'string'},
          },
          'required': ['city'],
        },
      ),
    ],
    toolChoice: const LocalToolChoice.auto(),
  ),
);

await for (final delta in localModels.chatStreamRequest(request)) {
  // Append delta.content to your UI.
  // If delta.toolCalls is not empty, execute tools in your app and send
  // LocalChatMessage.toolResult(...) in the next request.
}
```

For non-streaming use:

```dart
final response = await localModels.chatRequest(request);
```

## Runtime Contract

Implement `LocalChatRuntime` to connect the SDK to your runtime:

- `getModels()` returns installed or available model manifests.
- `chatStream(...)` streams `LocalChatDelta` chunks.
- The app owns tool execution; the runtime only returns tool call requests.
- Attachments carry local file URIs for image, audio, and arbitrary file inputs.

## Production Notes

- Keep model downloads and runtime execution outside widgets.
- Use `LocalChatRequest` for request logging, replay, and tests.
- Persist model metadata separately from model weights so release metadata can be
  refreshed without re-downloading large artifacts.
- Respect upstream model licenses; SDK code is MIT, model bundles are not
  automatically MIT.

## License

MIT.

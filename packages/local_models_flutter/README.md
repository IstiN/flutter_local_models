# local_models_flutter

Flutter SDK surface for local model runtimes.

The public chat shape is intentionally Flutter-native and model-agnostic:

```dart
final localModels = LocalModelsFlutter(chatRuntime: myRuntimeAdapter);

final models = await localModels.getModels();
final model = models.first;

final stream = localModels.chatStream(
  messages: [
    const LocalChatMessage.system('You are a concise local assistant.'),
    LocalChatMessage.user(
      'What is in this image?',
      attachments: [
        LocalMessageAttachment.file(
          type: LocalAttachmentType.image,
          path: '/Users/me/image.png',
        ),
      ],
    ),
  ],
  params: LocalChatParams(
    modelId: model.id,
    maxTokens: 256,
    temperature: 0.2,
    tools: [
      const LocalTool.function(
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

await for (final delta in stream) {
  // Append delta.content to your UI.
  // If delta.toolCalls is not empty, execute those tools and send
  // LocalChatMessage.toolResult(...) in the next chatStream call.
}
```

For non-streaming use, `chat(...)` consumes `chatStream(...)` and returns a
single `LocalChatResponse`. If the model requests tools, the returned assistant
message contains `message.toolCalls`; your app owns tool execution and sends
tool outputs back as `LocalChatMessage.toolResult(...)`.

Runtime adapters are still evolving. The macOS Studio app currently provides a
development adapter for MLX-backed local testing while the native bridge API is
being finalized.

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
  ),
);

await for (final delta in stream) {
  // Append delta.content to your UI.
}
```

For non-streaming use, `chat(...)` consumes `chatStream(...)` and returns a
single `LocalChatResponse`.

Runtime adapters are still evolving. The macOS Studio app currently provides a
development adapter for MLX-backed local testing while the native bridge API is
being finalized.

# local_models_core

Pure Dart core types for local model catalogs, runtime metadata, chat payloads,
tool calls, and release bundle planning.

This package has no Flutter dependency. Use it from Flutter apps, CLIs, test
tools, or model registry automation.

## Features

- Parse model manifests from YAML and catalog JSON.
- Represent text, image, audio, and file attachments in chat messages.
- Define OpenAI-style function tools and tool choices.
- Serialize `LocalChatRequest`, `LocalChatDelta`, and `LocalChatResponse`.
- Store runtime defaults such as context size, TTS voices, ASR language hints,
  output media metadata, and model-specific parameters.
- Build predictable GitHub release chunk plans for packaged model artifacts.

## Example

```dart
final registry = await ModelRegistry.loadDirectory('registry/models');
final model = registry.byId('qwen3-0.6b-4bit');

final request = LocalChatRequest(
  messages: [
    const LocalChatMessage.system('You are a concise local assistant.'),
    const LocalChatMessage.user('Say hello in Russian.'),
  ],
  params: LocalChatParams(
    modelId: model.id,
    maxTokens: 128,
    temperature: 0.2,
    tools: const [
      LocalTool.function(
        name: 'get_time',
        description: 'Return the current local time.',
      ),
    ],
    toolChoice: const LocalToolChoice.auto(),
  ),
);

final json = request.toJson();
```

## Model Metadata

`ModelRuntimeConfig` intentionally keeps provider-specific fields flexible:

- `defaultParameters` for generation defaults.
- `parameterSchema` for UI controls.
- `voices` for TTS speaker presets.
- `output` for generated media metadata.
- `extra` for adapter-specific MLX, MLX-VLM, MLX-Audio, or native bridge hints.

## License

MIT. Model weights keep their upstream licenses; check each manifest before
shipping a bundled model in a commercial app.

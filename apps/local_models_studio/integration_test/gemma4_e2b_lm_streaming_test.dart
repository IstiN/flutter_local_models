import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:local_models_flutter/local_models_flutter.dart';
import 'package:path/path.dart' as p;

/// macOS integration test for **Gemma 4 E2B IT 4bit** (`gemma4-e2b-it-4bit`).
///
/// Requires weights on disk. Default (same layout as Studio):
/// `StudioPaths.forCurrentUser().modelsDirectory/gemma4-e2b-it-4bit`
///
/// Override: `FLM_GEMMA_E2B_MODEL_DIR=/path/to/gemma4-e2b-it-4bit`
///
/// Run:
/// `cd apps/local_models_studio && flutter test integration_test/gemma4_e2b_lm_streaming_test.dart -d macos`
const _gemmaE2bId = 'gemma4-e2b-it-4bit';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Gemma 4 E2B IT 4bit streams assistant text (macOS)', (
    tester,
  ) async {
    if (!Platform.isMacOS) {
      markTestSkipped('requires macOS + native MLX bridge');
    }

    final envDir = Platform.environment['FLM_GEMMA_E2B_MODEL_DIR']?.trim();
    final fallbackPath = p.join(
      StudioPaths.forCurrentUser().modelsDirectory.path,
      _gemmaE2bId,
    );
    final modelPath =
        (envDir != null && envDir.isNotEmpty) ? envDir : fallbackPath;
    final dir = Directory(modelPath);

    if (!dir.existsSync()) {
      markTestSkipped(
        'No model at ${dir.path} — install $_gemmaE2bId or set '
        'FLM_GEMMA_E2B_MODEL_DIR',
      );
    }

    final catalogJson = await rootBundle.loadString('assets/catalog.json');
    final registry = ModelRegistry.fromCatalogJson(catalogJson);
    final manifest = registry.byId(_gemmaE2bId);
    final model = InstalledModel(
      manifest: manifest,
      directory: dir,
      sourceLabel: 'integration_test',
      installedAt: DateTime.now(),
      sizeBytes: 0,
    );

    final runner = LocalChatRunner();
    var onTextCalls = 0;
    var maxPartialLen = 0;
    final reply = await runner.chatStream(
      model: model,
      messages: const [
        LocalChatMessage.user('Reply with one word only: OK'),
      ],
      params: const LocalChatParams(maxTokens: 24, temperature: 0.0),
      onText: (partial) {
        onTextCalls++;
        if (partial.length > maxPartialLen) {
          maxPartialLen = partial.length;
        }
      },
    );

    expect(reply.trim(), isNotEmpty);
    expect(onTextCalls, greaterThan(0));
    expect(maxPartialLen, greaterThan(0));
  });
}

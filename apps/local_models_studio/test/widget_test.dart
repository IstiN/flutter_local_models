import 'package:flutter_test/flutter_test.dart';
import 'package:local_models_core/local_models_core.dart';
import 'package:local_models_studio/main.dart';

void main() {
  testWidgets('renders runtime and catalog information', (tester) async {
    await tester.pumpWidget(
      StudioApp(
        runtimeSummaryLoader: () async => const NativeRuntimeSummary(
          bridgeVersion: '0.1.0-test',
          platform: 'macOS test',
          metalAvailable: true,
          mlxFocused: true,
          ffiEnabled: true,
        ),
        registryLoader: () async => ModelRegistry(const [
          LocalModelManifest(
            id: 'gemma4-e4b-it-4bit',
            displayName: 'Gemma 4 E4B IT 4bit',
            description: 'Compact Gemma 4 vision + chat bundle.',
            runtimeAdapter: RuntimeAdapter.mlxVlm,
            tasks: [ModelTask.chat, ModelTask.vision],
            source: ModelSource(
              provider: 'huggingface',
              repo: 'mlx-community/gemma-4-e4b-it-4bit',
              revision: 'main',
              license: 'apache-2.0',
            ),
            packaging: PackagingSpec(
              releaseTag: 'model-gemma4-e4b-it-4bit',
              archiveName: 'gemma4-e4b-it-4bit.tar',
              chunkSizeBytes: 1900000000,
              assetPrefix: 'gemma4-e4b-it-4bit',
            ),
            requirements: SystemRequirements(
              platform: 'macos-apple-silicon',
              minMemoryGb: 16,
              recommendedMemoryGb: 24,
              notes: ['Vision capable'],
            ),
            capabilities: CapabilitySpec(
              audioInput: false,
              audioOutput: false,
              toolCalling: true,
            ),
          ),
        ]),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Local Models Studio'), findsOneWidget);
    expect(find.text('Bridge: 0.1.0-test'), findsOneWidget);
    expect(find.text('Gemma 4 E4B IT 4bit'), findsOneWidget);
    expect(find.text('Release: model-gemma4-e4b-it-4bit'), findsOneWidget);
  });
}

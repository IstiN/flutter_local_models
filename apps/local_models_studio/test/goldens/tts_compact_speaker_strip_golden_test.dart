import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Golden for the TTS compact strip layout (Speaker dropdown + Voice & model).
/// Run once locally after intentional UI changes:
///   flutter test test/goldens/tts_compact_speaker_strip_golden_test.dart --update-goldens
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TTS compact speaker strip matches golden', (tester) async {
    const speakerOptions = ['Vivian', 'Serena', 'Ryan', 'Aiden'];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF9B6BFF),
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xFF0D1020),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF2E314F),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
          ),
        ),
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Card(
                color: const Color(0xFF242640),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Speech voice',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Ryan • Language auto • Speed 1.0',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 210,
                        child: DropdownButtonFormField<String>(
                          initialValue: 'Ryan',
                          isDense: true,
                          decoration: const InputDecoration(
                            labelText: 'Speaker',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 10,
                            ),
                          ),
                          items: speakerOptions
                              .map(
                                (v) => DropdownMenuItem<String>(
                                  value: v,
                                  child: Text(v),
                                ),
                              )
                              .toList(),
                          onChanged: (_) {},
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        onPressed: () {},
                        child: const Text('Voice & model'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('tts_compact_speaker_strip.png'),
    );
  });
}

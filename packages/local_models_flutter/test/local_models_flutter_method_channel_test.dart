import 'package:flutter_test/flutter_test.dart';
import 'package:local_models_flutter/local_models_flutter_method_channel.dart';

void main() {
  test('returns an explicit disabled-bridge error', () async {
    final platform = MethodChannelLocalModelsFlutter();
    final summary = await platform.getRuntimeSummary();

    expect(summary.hasError, isTrue);
    expect(summary.errorMessage, contains('MethodChannel bridge is disabled'));
  });
}

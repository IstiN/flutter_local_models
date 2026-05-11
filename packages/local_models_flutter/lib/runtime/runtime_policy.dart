import 'dart:io';

import 'fallback_dispatch.dart';
import 'native_dispatch.dart';
import 'process_mlx_dispatch.dart';

/// Returned for LM/VLM/image when no platform-native `flm_dispatch_json` is
/// linked yet (everything except macOS in the default Studio build).
/// [FallbackFlmDispatcher] can still route **audio.*** to the **transitional**
/// Python mlx-audio CLI until an Android/Linux/Windows bridge ships.
final class FlmNonMacNativeStub implements FlmDispatching {
  @override
  Map<String, Object?> invoke(String operation, Map<String, Object?> payload) {
    return <String, Object?>{
      'ok': false,
      'error':
          'No native bridge for this OS yet (macOS uses FlmMLXRuntime / '
          'flm_dispatch_json). Other platforms will add their own native '
          'libraries; optional Python mlx-audio may still handle audio.* '
          'via subprocess if configured.',
    };
  }
}

FlmDispatching? _defaultFlmDispatch;

/// Shared [FlmDispatching] for production engines.
///
/// **macOS (priority):** Swift FFI via [FlmNativeDispatcher] first; Python
/// mlx-audio subprocess only for `audio.transcribe` / `audio.synthesize`
/// when native returns not OK — **stopgap** until Swift ASR/TTS replace it.
///
/// **Other OS:** stub primary + same optional Python audio path until each
/// platform ships a native bridge (Android/Linux/Windows load their own
/// `flm_dispatch_json` implementation or equivalent).
///
/// Environment:
/// - `FLM_MLX_PYTHON` — Python to use for subprocess (default `python3`).
/// - `FLM_PROCESS_MLX_ONLY` — skip Swift, use Python for audio only.
/// - `FLM_DISABLE_PROCESS_FALLBACK` — never call Python (Swift / stub only).
FlmDispatching defaultFlmDispatching() {
  return _defaultDispatch ??= _createDefaultFlmDispatching();
}

/// Visible for tests that must reset the lazy singleton.
void debugResetDefaultFlmDispatchingForTests() {
  _defaultFlmDispatch = null;
}

FlmDispatching _createDefaultFlmDispatching() {
  final process = ProcessFlmDispatcher();

  if (Platform.environment['FLM_PROCESS_MLX_ONLY'] == '1') {
    return process;
  }

  if (Platform.environment['FLM_DISABLE_PROCESS_FALLBACK'] == '1') {
    if (Platform.isMacOS) {
      return FlmNativeDispatcher();
    }
    return FlmNonMacNativeStub();
  }

  if (Platform.isMacOS) {
    return FallbackFlmDispatcher(
      primary: FlmNativeDispatcher(),
      fallback: process,
    );
  }

  return FallbackFlmDispatcher(
    primary: FlmNonMacNativeStub(),
    fallback: process,
  );
}

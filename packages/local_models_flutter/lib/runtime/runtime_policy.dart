import 'dart:io';

import 'fallback_dispatch.dart';
import 'native_dispatch.dart';
import 'process_mlx_dispatch.dart';

/// Returned for LM when no platform-native `flm_dispatch_json` is linked yet
/// (non-macOS in the default Studio build). `audio.*` and `image.generate` may
/// still use [ProcessFlmDispatcher] when using [FallbackFlmDispatcher].
final class FlmNonMacNativeStub implements FlmDispatching {
  @override
  bool get isBlockingInvoke => false;

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
/// **macOS:** native first ([FlmNativeDispatcher]). `image.generate` retries with
/// `mflux-generate*` on `PATH` when Swift is not implemented. Set
/// `FLM_ENABLE_PROCESS_FALLBACK=1` to also run **Python mlx-audio** for `audio.*`
/// after native failure.
///
/// **Other OS:** stub primary + Python mlx-audio / mflux subprocess for
/// `audio.*` and `image.generate` until a native bridge exists.
///
/// Environment:
/// - `FLM_MLX_PYTHON` — Python executable for subprocess fallback (default `python3`).
/// - `FLM_PROCESS_MLX_ONLY` — use **only** Python for `audio.*` (no Swift attempt).
/// - `FLM_ENABLE_PROCESS_FALLBACK=1` — on **macOS**, enable Python fallback after Swift failure.
/// - `FLM_DISABLE_PROCESS_FALLBACK=1` — on **non-macOS**, skip Python too (stub only).
FlmDispatching defaultFlmDispatching() {
  return _defaultFlmDispatch ??= _createDefaultFlmDispatching();
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

  if (Platform.isMacOS) {
    // Audio fallback is always enabled on macOS: Swift returns ok:false for
    // architectures it does not implement (VibeVoice, Whisper, …) and the
    // Python mlx-audio process takes over. For supported Qwen3 models Swift
    // succeeds and the fallback is never reached.
    // Set FLM_DISABLE_PROCESS_FALLBACK=1 to opt-out of the Python path entirely.
    final disableAudioFallback =
        Platform.environment['FLM_DISABLE_PROCESS_FALLBACK'] == '1';
    return FallbackFlmDispatcher(
      primary: FlmNativeDispatcher(),
      fallback: process,
      retryOperations: {
        'image.generate',
        if (!disableAudioFallback)
          ...FallbackFlmDispatcher.defaultAudioRetryOperations,
      },
    );
  }

  if (Platform.environment['FLM_DISABLE_PROCESS_FALLBACK'] == '1') {
    return FlmNonMacNativeStub();
  }

  return FallbackFlmDispatcher(
    primary: FlmNonMacNativeStub(),
    fallback: process,
    retryOperations: {
      ...FallbackFlmDispatcher.defaultAudioRetryOperations,
      'image.generate',
    },
  );
}

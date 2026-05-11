import 'native_dispatch.dart';

/// Runs [primary], and for `audio.transcribe` / `audio.synthesize` only, retries
/// with [fallback] when the primary result is not OK (e.g. Swift runtime not wired).
///
/// Other operations always return the primary outcome so LM / image stay on the
/// native path unless you add a separate policy.
final class FallbackFlmDispatcher implements FlmDispatching {
  FallbackFlmDispatcher({
    required FlmDispatching primary,
    required FlmDispatching fallback,
  }) : _primary = primary,
       _fallback = fallback;

  final FlmDispatching _primary;
  final FlmDispatching _fallback;

  static const _audioOps = {'audio.transcribe', 'audio.synthesize'};

  @override
  Map<String, Object?> invoke(String operation, Map<String, Object?> payload) {
    final first = _primary.invoke(operation, payload);
    if (first['ok'] == true) {
      return first;
    }
    if (!_audioOps.contains(operation)) {
      return first;
    }
    return _fallback.invoke(operation, payload);
  }
}

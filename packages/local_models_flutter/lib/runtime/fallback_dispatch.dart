import 'native_dispatch.dart';

/// Runs [primary], and for operations listed in [retryOperations] retries with
/// [fallback] when the primary result is not OK.
///
/// When [retryOperations] is omitted, defaults to [defaultAudioRetryOperations].
final class FallbackFlmDispatcher implements FlmDispatching {
  static const Set<String> defaultAudioRetryOperations = {
    'audio.transcribe',
    'audio.synthesize',
  };

  FallbackFlmDispatcher({
    required FlmDispatching primary,
    required FlmDispatching fallback,
    Set<String>? retryOperations,
  }) : _primary = primary,
       _fallback = fallback,
       _retryOps = retryOperations ?? defaultAudioRetryOperations;

  final FlmDispatching _primary;
  final FlmDispatching _fallback;
  final Set<String> _retryOps;

  /// Visible for streaming LM bridge (primary handles `lm.generate` natively).
  FlmDispatching get primary => _primary;

  @override
  bool get isBlockingInvoke =>
      _primary.isBlockingInvoke || _fallback.isBlockingInvoke;

  @override
  Map<String, Object?> invoke(String operation, Map<String, Object?> payload) {
    final first = _primary.invoke(operation, payload);
    if (first['ok'] == true) {
      return first;
    }
    if (!_retryOps.contains(operation)) {
      return first;
    }
    return _fallback.invoke(operation, payload);
  }
}

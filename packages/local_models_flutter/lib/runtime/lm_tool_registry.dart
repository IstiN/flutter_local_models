/// In-process registry for MLX LM tool handlers (name → Dart callback).
///
/// Used with [NativeLmEngine] / [LocalChatRunner] when `LocalChatParams.tools`
/// is non-empty: the Swift bridge invokes the matching handler over FFI.
final class LmToolRegistry {
  final Map<String, Future<String> Function(Map<String, Object?>)> _handlers =
      <String, Future<String> Function(Map<String, Object?>)>{};

  void register(
    String name,
    Future<String> Function(Map<String, Object?> arguments) handler,
  ) {
    _handlers[name] = handler;
  }

  void registerSync(
    String name,
    String Function(Map<String, Object?> arguments) handler,
  ) {
    _handlers[name] = (args) async => handler(args);
  }

  bool provides(String name) => _handlers.containsKey(name);

  Future<String> invoke(String name, Map<String, Object?> arguments) async {
    final h = _handlers[name];
    if (h == null) {
      throw StateError('No tool handler registered for "$name".');
    }
    return h(arguments);
  }
}

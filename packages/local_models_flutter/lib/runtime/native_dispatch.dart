import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:local_models_core/local_models_core.dart';

/// JSON dispatcher into macOS native code (`flm_dispatch_json` in the plugin).
abstract class FlmDispatching {
  Map<String, Object?> invoke(String operation, Map<String, Object?> payload);
}

typedef _DispatchNative = Pointer<Utf8> Function(
  Pointer<Utf8> op,
  Pointer<Utf8> json,
);
typedef _DispatchDart = Pointer<Utf8> Function(Pointer<Utf8> op, Pointer<Utf8> json);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

final class FlmNativeDispatcher implements FlmDispatching {
  FlmNativeDispatcher();

  DynamicLibrary? _lib;
  _DispatchDart? _dispatch;
  _FreeDart? _free;

  void _ensureLoaded() {
    if (_lib != null) {
      return;
    }
    if (!Platform.isMacOS) {
      throw UnsupportedError(
        'Native MLX dispatch requires macOS. Use a fake [FlmDispatching] in tests '
        'or inject a custom engine.',
      );
    }
    _lib = DynamicLibrary.process();
    _dispatch = _lib!.lookupFunction<_DispatchNative, _DispatchDart>(
      'flm_dispatch_json',
    );
    _free = _lib!.lookupFunction<_FreeNative, _FreeDart>(
      'flm_bridge_free_string',
    );
  }

  @override
  Map<String, Object?> invoke(String operation, Map<String, Object?> payload) {
    _ensureLoaded();
    final opPtr = operation.toNativeUtf8();
    final jsonPtr = jsonEncode(payload).toNativeUtf8();
    try {
      final outPtr = _dispatch!(opPtr, jsonPtr);
      if (outPtr.address == 0) {
        throw StateError('flm_dispatch_json returned null');
      }
      try {
        final jsonStr = outPtr.toDartString();
        final decoded = jsonDecode(jsonStr);
        if (decoded is! Map) {
          throw FormatException('Expected JSON object, got: $jsonStr');
        }
        return Map<String, Object?>.from(
          decoded.map((key, value) => MapEntry('$key', value)),
        );
      } finally {
        _free!(outPtr);
      }
    } finally {
      malloc.free(opPtr);
      malloc.free(jsonPtr);
    }
  }
}

/// Test double that records calls and returns a scripted result.
final class RecordingFlmDispatcher implements FlmDispatching {
  RecordingFlmDispatcher();

  final List<({String op, Map<String, Object?> payload})> calls =
      <({String op, Map<String, Object?> payload})>[];

  Map<String, Object?> Function(String op, Map<String, Object?> payload)?
  onInvoke;

  @override
  Map<String, Object?> invoke(String operation, Map<String, Object?> payload) {
    calls.add((op: operation, payload: Map<String, Object?>.from(payload)));
    return onInvoke?.call(operation, payload) ??
        <String, Object?>{'ok': false, 'error': 'recording dispatcher: no handler'};
  }
}

String runtimeAdapterWireName(RuntimeAdapter adapter) {
  switch (adapter) {
    case RuntimeAdapter.mlxLm:
      return 'mlx_lm';
    case RuntimeAdapter.mlxVlm:
      return 'mlx_vlm';
    case RuntimeAdapter.mlxAudio:
      return 'mlx_audio';
    case RuntimeAdapter.mflux:
      return 'mflux';
    case RuntimeAdapter.nativeBridge:
      return 'native_bridge';
  }
}

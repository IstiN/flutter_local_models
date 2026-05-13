import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:local_models_core/local_models_core.dart';

/// JSON dispatcher into macOS native code (`flm_dispatch_json` in the plugin).
abstract class FlmDispatching {
  Map<String, Object?> invoke(String operation, Map<String, Object?> payload);

  /// When true, [invoke] may block the calling isolate for a long time (FFI LM,
  /// subprocess, etc.). Async surfaces should run it on a worker isolate.
  bool get isBlockingInvoke => true;
}

typedef _DispatchNative = Pointer<Utf8> Function(
  Pointer<Utf8> op,
  Pointer<Utf8> json,
);
typedef _DispatchDart = Pointer<Utf8> Function(Pointer<Utf8> op, Pointer<Utf8> json);
typedef NativeFlmStreamChunk = Void Function(Pointer<Utf8> chunk, Pointer<Void> userData);
typedef DartFlmStreamChunk = void Function(Pointer<Utf8> chunk, Pointer<Void> userData);
typedef NativeFlmToolRequest = Void Function(Pointer<Utf8> requestJson, Pointer<Void> userData);
typedef _ToolCompleteNative = Void Function(Pointer<Utf8> result);
typedef _ToolCompleteDart = void Function(Pointer<Utf8> result);
typedef _ToolAbortNative = Void Function(Pointer<Utf8> err);
typedef _ToolAbortDart = void Function(Pointer<Utf8> err);
typedef _DispatchStreamNative = Pointer<Utf8> Function(
  Pointer<Utf8> op,
  Pointer<Utf8> json,
  Pointer<NativeFunction<NativeFlmStreamChunk>> onChunk,
  Pointer<Void> userData,
);
typedef _DispatchStreamDart = Pointer<Utf8> Function(
  Pointer<Utf8> op,
  Pointer<Utf8> json,
  Pointer<NativeFunction<NativeFlmStreamChunk>> onChunk,
  Pointer<Void> userData,
);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

final class FlmNativeDispatcher implements FlmDispatching {
  FlmNativeDispatcher();

  @override
  bool get isBlockingInvoke => true;

  DynamicLibrary? _lib;
  _DispatchDart? _dispatch;
  _DispatchStreamDart? _dispatchStream;
  _FreeDart? _free;
  _ToolCompleteDart? _toolComplete;
  _ToolAbortDart? _toolAbort;

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
    _dispatchStream = _lib!.lookupFunction<_DispatchStreamNative, _DispatchStreamDart>(
      'flm_dispatch_json_stream',
    );
    _free = _lib!.lookupFunction<_FreeNative, _FreeDart>(
      'flm_bridge_free_string',
    );
  }

  void _ensureToolBridgeLoaded() {
    _ensureLoaded();
    _toolComplete ??= _lib!.lookupFunction<_ToolCompleteNative, _ToolCompleteDart>(
      'flm_tool_bridge_complete',
    );
    _toolAbort ??= _lib!.lookupFunction<_ToolAbortNative, _ToolAbortDart>(
      'flm_tool_bridge_abort',
    );
  }

  /// Notifies Swift that a tool finished successfully ([result] is copied in native code).
  void completeToolBridge(String result) {
    _ensureToolBridgeLoaded();
    final ptr = result.toNativeUtf8();
    try {
      _toolComplete!(ptr);
    } finally {
      malloc.free(ptr);
    }
  }

  /// Notifies Swift that a tool failed.
  void abortToolBridge(String message) {
    _ensureToolBridgeLoaded();
    final ptr = message.toNativeUtf8();
    try {
      _toolAbort!(ptr);
    } finally {
      malloc.free(ptr);
    }
  }

  /// Chunk deltas (UTF-8). [onChunkNativeAddress] is the address of a
  /// `NativeCallable.listener` whose C signature matches [NativeFlmStreamChunk].
  /// Only supported for `lm.generate`; blocks the calling isolate until done.
  Map<String, Object?> invokeLmGenerateStream(
    Map<String, Object?> payload,
    int onChunkNativeAddress,
  ) {
    _ensureLoaded();
    final opPtr = 'lm.generate'.toNativeUtf8();
    final jsonPtr = jsonEncode(payload).toNativeUtf8();
    final chunkPtr = Pointer<NativeFunction<NativeFlmStreamChunk>>.fromAddress(
      onChunkNativeAddress,
    );
    try {
      final outPtr = _dispatchStream!(opPtr, jsonPtr, chunkPtr, nullptr);
      if (outPtr.address == 0) {
        throw StateError('flm_dispatch_json_stream returned null');
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

  @override
  bool get isBlockingInvoke => false;

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

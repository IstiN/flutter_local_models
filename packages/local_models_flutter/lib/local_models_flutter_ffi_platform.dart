import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:local_models_core/local_models_core.dart';

import 'local_models_flutter_platform_interface.dart';

typedef _GetSummaryNative = Pointer<Utf8> Function();
typedef _GetSummaryDart = Pointer<Utf8> Function();
typedef _FreeStringNative = Void Function(Pointer<Utf8>);
typedef _FreeStringDart = void Function(Pointer<Utf8>);

class FfiLocalModelsFlutterPlatform extends LocalModelsFlutterPlatform {
  FfiLocalModelsFlutterPlatform({DynamicLibrary? dynamicLibrary})
    : _dynamicLibrary = dynamicLibrary ?? DynamicLibrary.process();

  final DynamicLibrary _dynamicLibrary;

  @override
  Future<NativeRuntimeSummary> getRuntimeSummary() async {
    try {
      final getSummary = _dynamicLibrary
          .lookupFunction<_GetSummaryNative, _GetSummaryDart>(
            'flm_bridge_runtime_summary_json',
          );
      final freeString = _dynamicLibrary
          .lookupFunction<_FreeStringNative, _FreeStringDart>(
            'flm_bridge_free_string',
          );

      final pointer = getSummary();
      final jsonString = pointer.toDartString();
      freeString(pointer);

      return NativeRuntimeSummary.fromJsonMap(
        jsonDecode(jsonString) as Map<String, Object?>,
      );
    } on ArgumentError catch (error) {
      return NativeRuntimeSummary.error('FFI symbol lookup failed: $error');
    } on FormatException catch (error) {
      return NativeRuntimeSummary.error('Invalid bridge payload: $error');
    }
  }
}

import 'package:local_models_core/local_models_core.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'local_models_flutter_ffi_platform.dart';

abstract class LocalModelsFlutterPlatform extends PlatformInterface {
  LocalModelsFlutterPlatform() : super(token: _token);

  static final Object _token = Object();

  static LocalModelsFlutterPlatform _instance = FfiLocalModelsFlutterPlatform();

  static LocalModelsFlutterPlatform get instance => _instance;

  static set instance(LocalModelsFlutterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<NativeRuntimeSummary> getRuntimeSummary() {
    throw UnimplementedError('getRuntimeSummary() has not been implemented.');
  }
}

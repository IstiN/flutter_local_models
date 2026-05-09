import 'package:local_models_core/local_models_core.dart';

import 'local_models_flutter_platform_interface.dart';

class MethodChannelLocalModelsFlutter extends LocalModelsFlutterPlatform {
  @override
  Future<NativeRuntimeSummary> getRuntimeSummary() async {
    return NativeRuntimeSummary.error(
      'MethodChannel bridge is disabled. Use the FFI platform implementation.',
    );
  }
}

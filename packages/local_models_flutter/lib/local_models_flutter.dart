library;

import 'package:local_models_core/local_models_core.dart';

import 'local_models_flutter_platform_interface.dart';

class LocalModelsFlutter {
  Future<NativeRuntimeSummary> getRuntimeSummary() {
    return LocalModelsFlutterPlatform.instance.getRuntimeSummary();
  }
}

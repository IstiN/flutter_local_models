import 'dart:async';
import 'dart:io';

class LocalModelsPrerequisitesStatus {
  const LocalModelsPrerequisitesStatus({
    required this.platformSupported,
    required this.metalToolchainAvailable,
    this.metalPath,
    this.message,
    this.installHint,
  });

  final bool platformSupported;
  final bool metalToolchainAvailable;
  final String? metalPath;
  final String? message;
  final String? installHint;

  bool get isReady => platformSupported && metalToolchainAvailable;
}

class LocalModelsPrerequisitesChecker {
  static const String metalToolchainInstallCommand =
      'xcodebuild -downloadComponent MetalToolchain';

  static Future<LocalModelsPrerequisitesStatus> check({
    Map<String, String>? environment,
  }) async {
    if (!Platform.isMacOS) {
      return const LocalModelsPrerequisitesStatus(
        platformSupported: false,
        metalToolchainAvailable: false,
        message: 'Local AI models are currently supported only on macOS.',
      );
    }

    try {
      final result = await Process.run('xcrun', [
        '--find',
        'metal',
      ], environment: environment).timeout(const Duration(seconds: 5));
      final path = (result.stdout as String).trim();
      if (result.exitCode == 0 && path.isNotEmpty) {
        return LocalModelsPrerequisitesStatus(
          platformSupported: true,
          metalToolchainAvailable: true,
          metalPath: path,
        );
      }
    } on Exception {
      // fall through to missing-toolchain status
    }

    return const LocalModelsPrerequisitesStatus(
      platformSupported: true,
      metalToolchainAvailable: false,
      message:
          'Metal Toolchain is required for local models on macOS and is not installed.',
      installHint: metalToolchainInstallCommand,
    );
  }

  static Future<LocalModelsPrerequisitesStatus> installMissingPrerequisites({
    Map<String, String>? environment,
  }) async {
    final before = await check(environment: environment);
    if (!before.platformSupported || before.metalToolchainAvailable) {
      return before;
    }
    final installResult = await Process.run('xcodebuild', [
      '-downloadComponent',
      'MetalToolchain',
    ], environment: environment).timeout(const Duration(minutes: 15));
    if (installResult.exitCode != 0) {
      throw ProcessException(
        'xcodebuild',
        const ['-downloadComponent', 'MetalToolchain'],
        (installResult.stderr as String).trim(),
        installResult.exitCode,
      );
    }
    return check(environment: environment);
  }
}

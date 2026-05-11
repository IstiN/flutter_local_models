#!/usr/bin/env bash
# Run (or build) local_models_studio on macOS.
#
# mlx-swift-lm ships the MLXHuggingFaceMacros Swift macro. Flutter invokes
# xcodebuild without -skipMacroValidation, so the first build can fail with:
#   Macro "MLXHuggingFaceMacros" ... must be enabled before it can be used
#
# Apple documents trusting macros for xcodebuild via:
#   defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
#
# Revert on your machine (optional):
#   defaults delete com.apple.dt.Xcode IDESkipMacroFingerprintValidation
#
# Usage:
#   ./tools/run_local_models_studio_macos.sh              # flutter run -d macos
#   ./tools/run_local_models_studio_macos.sh --release    # passed to flutter run
#   ./tools/run_local_models_studio_macos.sh build        # flutter build macos

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

cd "$ROOT/apps/local_models_studio"

if [[ "${1:-}" == "build" ]]; then
  shift
  exec flutter build macos "$@"
fi

exec flutter run -d macos "$@"

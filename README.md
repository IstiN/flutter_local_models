# flutter_local_models

Flutter-first local AI runtime for Apple Silicon.

This project is building a native Flutter bridge for running local models on-device, starting with an `MLX`-focused backend on macOS. The long-term goal is simple: Flutter apps should be able to discover, install, load, and use local models without depending on a separate daemon or managing local ports.

## What this repo is

- a `Flutter plugin` for local AI runtimes
- a `native bridge` approach instead of a background server
- a `macOS-first` implementation for Apple Silicon
- a foundation for `chat`, `speech-to-text`, `text-to-speech`, and future multimodal adapters

## What this repo is not

- not an app-specific assistant
- not a hosted API wrapper
- not a model zoo with bundled weights checked into git
- not locked to a single runtime forever, even though `MLX` is the first focus

## Why native bridge

We are intentionally starting with `FFI + native bridge` instead of a local daemon.

That gives us a cleaner product story for Flutter developers:

- no port conflicts
- no background server lifecycle to babysit
- no extra “start service first” step
- a more natural path toward embedding local AI directly into desktop apps

If a service layer becomes useful later, we can add it as an optional adapter instead of making it the core requirement.

## Current shape

Today the repo contains the first product skeleton:

- `packages/local_models_core` — pure Dart types for manifests, registry loading, release planning, and runtime summaries
- `packages/local_models_flutter` — Flutter plugin with a macOS native FFI bridge
- `apps/local_models_studio` — desktop app for catalog browsing, resumable downloads, and local text/audio/image testing
- `apps/local_models_cli` — CLI companion for registry and packaging flows
- `native/mlx_bridge` — standalone Swift package that will evolve into the shared MLX runtime layer

The native runtime is still a scaffold, but the project structure is now aligned with the intended product direction.

## Product direction

The target developer experience looks like this:

1. Add a Flutter package
2. Check runtime capabilities from Dart
3. Install or repair a local model bundle
4. Open a local session through the native bridge
5. Run inference from Flutter without spinning up a daemon

That means the most important future work is:

- real `MLX` session loading and inference
- robust install/repair/download flows
- resumable bundle delivery
- stable Dart APIs for text, audio, and multimodal use cases

## Repository layout

```text
packages/
  local_models_core/      # Pure Dart contracts and registry logic
  local_models_flutter/   # Flutter plugin + FFI bridge
apps/
  local_models_cli/       # CLI for dev and packaging workflows
  local_models_studio/    # Minimal desktop management UI
native/
  mlx_bridge/             # Shared Swift runtime layer
tools/
  model_release/          # Packaging automation for release assets
registry/
  models/                 # Internal manifest source for release workflows
```

## Integrating into your own Flutter app

If you consume this repo from **another repository**, use a **full checkout** (e.g. git submodule) and a **`path:`** dependency on `packages/local_models_flutter` or `packages/local_models_sdk`. You must also link the **macOS Swift** runtime (**FlmMLXRuntime**) for local LM / native Qwen ASR–TTS.

Step-by-step guide: **[docs/INTEGRATION.md](docs/INTEGRATION.md)** (downloads, ASR + chat wiring, checklist).

## Flutter-first API direction

The intended public API should feel like Flutter, not like shell orchestration.

Example direction:

```dart
final localModels = LocalModelsFlutter();
final runtime = await localModels.getRuntimeSummary();
```

This is deliberately small right now. We want to grow it carefully into a stable API surface instead of exposing raw runtime internals too early.

## Local development

### Prerequisites

- `macOS` on Apple Silicon
- `Flutter stable`
- `Xcode` with command line tools
- `Python 3` for packaging scripts and tests

### Setup

```bash
git clone https://github.com/IstiN/flutter_local_models.git
cd flutter_local_models

python3 -m venv .venv
./.venv/bin/python -m pip install -r tools/model_release/requirements.txt

(cd packages/local_models_core && dart pub get)
(cd packages/local_models_flutter && flutter pub get)
(cd apps/local_models_cli && dart pub get)
(cd apps/local_models_studio && flutter pub get)
```

### Run tests

```bash
(cd packages/local_models_core && dart test)
(cd apps/local_models_cli && dart test)
(cd packages/local_models_flutter && flutter test)
(cd apps/local_models_studio && flutter test)
swift test --package-path native/mlx_bridge
./.venv/bin/python -m unittest discover -s tests/python
```

## Automation

The repo already includes:

- `CI` for Dart, Flutter, Swift, and Python tests
- a `release-model` workflow that can turn an external model source into resumable release assets

This packaging layer exists to support installation workflows for the Flutter runtime. It is infrastructure for the plugin ecosystem, not the primary public story of the repository.

If you need access to gated Hugging Face assets in automation, add `HF_TOKEN` as a repository secret.

## Local benchmarks

Local runtime smoke metrics are kept in `benchmarks/README.md`.

To refresh the report against the models installed by `apps/local_models_studio`, run:

```bash
python3 tools/benchmark_installed_models.py --chat-max-tokens 32 --image-steps-cap 1
```

The benchmark writes a human-readable summary plus a timestamped JSON artifact with raw command tails and generated media metadata.

## Roadmap

### Near term

- implement the first real `MLX` text runtime
- add install/download/repair APIs to the Flutter package
- keep polishing the Studio app as a production-quality SDK showcase
- add end-to-end tests around install and runtime bootstrap

### After that

- native speech-to-text adapter
- native text-to-speech adapter
- native multimodal adapter support
- optional non-MLX backends behind the same Dart contracts

## Status

Early, but intentionally structured.

The important thing already in place is the architecture: Flutter package, native bridge, companion UI, CLI, release automation, and tests all live in one repo and point toward the same product.

## License

MIT

# flutter_local_models

Flutter-first local AI runtime for Apple Silicon, starting with MLX.

This repo is intentionally shaped as a product skeleton, not a throwaway demo:

- `packages/local_models_core` — pure Dart manifest, registry, release-plan, and runtime-summary types
- `packages/local_models_flutter` — Flutter package with a macOS-native FFI bridge
- `apps/local_models_studio` — minimal desktop UI for catalog and runtime management
- `apps/local_models_cli` — CLI for registry inspection and install/release planning
- `native/mlx_bridge` — standalone Swift package for the future shared native runtime
- `registry/models` — source-of-truth model manifests
- `tools/model_release` — Hugging Face → archive chunks → GitHub Release packaging pipeline

## MVP direction

The current MVP focuses on:

- `macOS + Apple Silicon`
- `MLX-first adapters`
- GitHub Releases as the bundle distribution format
- resumable model bundling and deterministic chunked archives
- a Flutter wrapper that can later grow from local management into full inference UX

## Seed model set

The repo is pre-wired with manifests for:

- `mlx-community/gemma-4-e4b-it-4bit`
- `mlx-community/Qwen3-8B-4bit`
- `mlx-community/Qwen2-Audio-7B-Instruct-4bit`
- `mlx-community/Qwen3-ASR-0.6B-4bit`
- `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit`

## GitHub workflows

- `ci.yml` runs Dart, Flutter, Swift, and Python tests
- `release-model.yml` downloads one manifest-defined model, archives it, splits it into release-safe parts, and publishes one GitHub Release per model

## Local dev

```bash
cd /Users/uladzimir_klyshevich/git/flutter_local_models

python3 -m venv .venv
./.venv/bin/python -m pip install -r tools/model_release/requirements.txt

(cd packages/local_models_core && dart pub get)
(cd packages/local_models_flutter && flutter pub get)
(cd apps/local_models_cli && dart pub get)
(cd apps/local_models_studio && flutter pub get)

(cd packages/local_models_core && dart test)
(cd apps/local_models_cli && dart test)
(cd packages/local_models_flutter && flutter test)
(cd apps/local_models_studio && flutter test)
swift test --package-path native/mlx_bridge
./.venv/bin/python -m unittest discover -s tests/python
```

## Immediate next build-out

- replace the placeholder native bridge with real MLX runtime loading/session APIs
- add GitHub Release install/download logic to the Flutter package
- add signed model bundle manifests and repair flows
- add direct install/uninstall actions in the desktop app

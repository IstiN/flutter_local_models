# Integrating `flutter_local_models` into your Flutter app

This guide explains how to depend on this monorepo from **another repository** and wire up **model downloads**, **ASR**, and **chat** on **macOS** (Apple Silicon). For native FFI details, see [MLX_RUNTIME_ARCHITECTURE.md](MLX_RUNTIME_ARCHITECTURE.md).

---

## 1. Why you must vendor the whole monorepo

Packages are **not published** to pub.dev (`publish_to: none`). `local_models_flutter` depends on siblings via **`path:`**:

| Package              | Depends on                    |
|----------------------|-------------------------------|
| `local_models_flutter` | `local_models_core`, `local_models_sdk` |
| `local_models_sdk`     | `local_models_core`           |

You **cannot** point `pubspec.yaml` at a single subdirectory of this repo on GitHub with one `git:` dependency and expect `pub get` to work. You need a **local checkout that preserves**:

```text
<vendor>/flutter_local_models/
  packages/local_models_core/
  packages/local_models_sdk/
  packages/local_models_flutter/
```

---

## 2. Add the repo to your project

Pick one approach:

### A. Git submodule (recommended)

From your app repository root:

```bash
git submodule add https://github.com/IstiN/flutter_local_models.git third_party/flutter_local_models
git submodule update --init --recursive
```

### B. Git subtree or manual clone

Clone or subtree-merge the same repo into e.g. `third_party/flutter_local_models/`.

### C. `pubspec.yaml` path dependency

In **your** app’s `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter

  local_models_flutter:
    path: third_party/flutter_local_models/packages/local_models_flutter
```

Then run:

```bash
flutter pub get
```

`pub` resolves `../local_models_core` and `../local_models_sdk` **relative to** `packages/local_models_flutter`, so the directory layout above must stay intact.

### Dart-only (no Flutter plugin / no native MLX)

If you only need manifests, storage paths, downloads, and headless runners without linking Swift MLX:

```yaml
dependencies:
  local_models_sdk:
    path: third_party/flutter_local_models/packages/local_models_sdk
```

You will **not** get macOS `flm_dispatch_json` / native ASR-TTS unless you also integrate `local_models_flutter` and the Runner steps below.

---

## 3. macOS app: native runtime (required for local LM / Qwen ASR–TTS)

The Flutter plugin loads **`flm_dispatch_json`** from the **main macOS executable**. Your Runner must link **FlmMLXRuntime** (SwiftPM), same pattern as **local_models_studio**.

**Do this:**

1. Enable Swift Package Manager for macOS in Flutter (`enable-swift-package-manager`).
2. Open `macos/Runner.xcworkspace` in Xcode.
3. Add the local Swift package:
   - Path: `third_party/flutter_local_models/packages/local_models_flutter/macos/FlmMLXRuntime`  
     (or equivalent relative to your project).
4. Link **FlmMLXRuntime** to the **Runner** target (Frameworks / “Embed & Sign” as needed).
5. Compare with the reference app:
   - `apps/local_models_studio/macos/` — `Podfile`, Runner project, SPM wiring.

Without this step, **`lm.generate`**, **`audio.transcribe`**, and **`audio.synthesize`** will fail at runtime on macOS (symbol missing or stub).

See also: [MLX_RUNTIME_ARCHITECTURE.md](MLX_RUNTIME_ARCHITECTURE.md) (operations, env vars, Python fallback).

---

## 4. Managing model downloads and installed bundles

Use **`local_models_sdk`** (re-exports `local_models_core` types).

| Concern | Starting points (Dart) |
|--------|-------------------------|
| Default dirs (models root, cache) | `LocalModelsSdkPaths.forCurrentUser()` in `model_store.dart` |
| List / install metadata on disk   | `LocalModelStore` — `listInstalledModels()`, `installedModelById()` |
| Resumable HTTP downloads + install  | `LocalModelDownloadManager` in `downloads.dart` |
| GitHub Release assets (`.part` → tarball) | `fetchGitHubReleaseFileDescriptors`, `installGitHubReleaseFromStageDirectory`, `LocalModelDownloadManager.downloadAndInstallFromGitHubRelease` |

**Registry / catalog:** ship or fetch `ModelRegistry` / manifests (`registry/models/*.yaml` or your own JSON) so `LocalModelManifest` IDs match directories under the models folder.

**Studio reference:** `apps/local_models_studio` shows UI around the same store and download flows; copy patterns, not necessarily the widgets.

---

## 5. ASR + chat integration (two-step mental model)

On macOS, native chat does **not** accept raw `audioPath` in `lm.generate` for all stacks: the Dart layer typically **transcribes first**, then sends a **text** prompt to the LM (see Studio / dispatch comments in `FlmDispatch.swift`).

**Building blocks in this repo:**

| Step | API layer | Notes |
|------|-----------|--------|
| Speech → text | `NativeAudioEngine` (`local_models_flutter`, `runtime/native_engines.dart`) — `transcribe()` → dispatch `audio.transcribe` | Native **Qwen3-ASR** in Swift; Whisper often needs Python fallback / env — see architecture doc. |
| Text → assistant | `LocalChatRunner` (`local_models_sdk`, `runtime.dart`) or `NativeLmEngine` | Pass `InstalledModel`, messages, `LocalChatParams`. |
| End-to-end voice UX | `StreamingVoice2VoicePipeline` (`voice2voice_streaming.dart`) | Orchestrates ASR → streaming LLM → TTS events; Studio’s Voice pipeline wraps this. |

**Suggested flow for your app:**

1. Resolve **`InstalledModel`** for ASR and for chat (from `LocalModelStore`).
2. Call **`NativeAudioEngine.transcribe`** with ASR model path + `LocalModelManifest` + audio file path.
3. Build **`LocalChatMessage`** list including the transcript (and system prompt if needed).
4. Run **`LocalChatRunner.chatStream`** (or non-stream variant) with the **chat** model.

**Product note:** Native **Gemma 4** speech-to-text through the same checkpoint is **disabled by default** in this repo (`kNativeGemma4AsrEnabled`); use a dedicated **mlx_audio** ASR checkpoint (e.g. Qwen3-ASR) for voice input, and Gemma (or any LM) for chat.

**Code references:**

- Chat stream example: `packages/local_models_flutter/README.md`
- Dispatch JSON ops: `docs/MLX_RUNTIME_ARCHITECTURE.md`

---

## 6. Checklist before shipping

- [ ] Submodule / folder layout keeps `packages/local_models_{core,sdk,flutter}` siblings.
- [ ] `flutter pub get` succeeds in your app.
- [ ] macOS **Runner** links **FlmMLXRuntime**; app launches without missing symbol for `flm_dispatch_json`.
- [ ] Models install to the path your `LocalModelStore` / `LocalModelsSdkPaths` uses.
- [ ] ASR manifest uses a runtime Swift supports (see architecture doc); chat manifest matches `mlx_lm` / `mlx_vlm` as expected by `LocalChatRunner`.

---

## 7. Support and upstream

- Issues / PRs: [github.com/IstiN/flutter_local_models](https://github.com/IstiN/flutter_local_models)
- License: MIT (see root `README.md`; model **weights** remain under their own licenses).

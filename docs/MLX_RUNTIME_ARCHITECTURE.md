# Native MLX runtime architecture (Flutter → FFI → macOS)

## Goal

- **Priority: macOS.** Run as much as possible through **native code** (Swift / MLX **mlx-swift-lm** for chat/VLM, **[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)** for **Qwen3** ASR/TTS) via **FFI** — `flm_dispatch_json` — with **Python subprocesses only as a transitional fallback** for Whisper or non-Qwen audio checkpoints until broader Swift coverage lands.
- **Other desktop / mobile (Android, Linux, Windows, iOS):** the same Dart **`FlmDispatching` contract** (`operation` + JSON payload) is meant to be backed by **platform-specific native bridges** (JNI, NDK, separate `.so` / DLL load, etc.). There is no plan to standardize on Python long-term; bridges may still call into a Python runtime somewhere in edge cases, but the product direction is **maximum native** per OS.
- **Interfaces stay stable:** `LmEngine`, `AudioEngine`, `ImageEngine` do not care whether the host is MLX, LiteRT, Core ML, or vendor APIs — only that something implements the dispatch JSON contract or an explicit process policy for that platform.

## Layers

1. **Dart (`local_models_flutter`)**  
   - `LmEngine`, `AudioEngine`, `ImageEngine` — small async APIs used by `LocalChatRunner`, `LocalAudioRunner`, `LocalImageRunner`.  
   - **`defaultFlmDispatching()`** — **macOS:** **Swift FFI first** (`flm_dispatch_json`), then **optional Python subprocess** for `audio.transcribe` / `audio.synthesize` only when the native result is not OK ([MLX-Audio](https://github.com/Blaizzy/mlx-audio) CLI) — **intended to shrink** as Swift ASR/TTS land.  
   - **Other OS:** primary is a **stub** until a native library is linked; **audio** may still use the same Python CLI as a stopgap. Replace the stub with **`DynamicLibrary.open(...)`** (or embed) to your platform bridge when ready.

2. **Host macOS app (Runner)**  
   - The C symbol `flm_dispatch_json` is implemented in the **FlmMLXRuntime** local Swift package  
     (`packages/local_models_flutter/macos/FlmMLXRuntime`), linking **mlx-swift-lm** (chat/VLM) and **[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)** (Qwen3 ASR/TTS from local model dirs).  
   - The Swift package manifest uses **Swift 6.2** toolchain semantics (via `swift-tools-version`); use a current **Xcode** that matches when resolving SPM.  
   - The Runner target links that package (SwiftPM) so `DynamicLibrary.process()` in Dart resolves the symbol from the main executable.  
   - The Flutter plugin (`LocalModelsFlutterPlugin.swift`) only provides `flm_bridge_*` helpers; it does **not** define `flm_dispatch_json` to avoid duplicating the entry point.

3. **Reference implementations (Swift on Apple platforms)**

   - **LLM / VLM:** [ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) — already linked from **FlmMLXRuntime**.  
   - **TTS / ASR (Qwen3 in Swift):** [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) — used in **FlmMLXRuntime** for `audio.transcribe` / `audio.synthesize` on **Qwen3-ASR** and **Qwen3-TTS** checkpoints.  
   - **Standalone ASR (optional):** [ontypehq/mlx-swift-asr](https://github.com/ontypehq/mlx-swift-asr) — alternative Qwen3-ASR API; not linked here because mlx-audio-swift already covers Qwen3 ASR.
   - **Cross‑platform Gemma-style:** [DenisovAV/flutter_gemma](https://github.com/DenisovAV/flutter_gemma) — pattern for **iOS/Android** with a non-MLX backend behind the same Dart API.

4. **Open-source Python parity (subprocess, transitional)**  

   When **native** code does not implement an audio operation (or before a platform bridge exists), Dart can fall back to the CLIs documented in [mlx-audio](https://github.com/Blaizzy/mlx-audio). This keeps feature parity while **macOS Swift** (and later **other native bridges**) catch up. **Goal:** rely on Python less over time, not more.

## Platform roadmap (native bridges)

| Platform | Direction |
|----------|-----------|
| **macOS** | **First priority:** **FlmMLXRuntime** (SwiftPM), expand LM/VLM/ASR/TTS in Swift; Python audio fallback optional. |
| **Android** | Future: JNI/NDK bridge implementing the same JSON ops (e.g. LiteRT, GPU delegates, vendor NPU) — separate from MLX Swift. |
| **Linux / Windows** | Future: load a native shared library / plugin that exports `flm_dispatch_json` or a thin shim with the same semantics. |
| **iOS** | Same pattern as macOS where Apple stack allows; otherwise Core ML / on-device APIs behind the same Dart engines. |

Apps choose their **primary** dispatcher per build flavor: today `defaultFlmDispatching()` encodes macOS + optional Python; tomorrow **`FLM_DISABLE_PROCESS_FALLBACK=1`** becomes the default shipping profile on macOS once Swift audio is complete.

## Operations (contract)

| `operation`        | Payload (summary)                          | Success response                          |
|--------------------|---------------------------------------------|-------------------------------------------|
| `lm.generate`      | `modelPath`, `adapter`, `prompt`, `maxTokens`, `temperature`, `topP`, optional `imagePath` | `{ "ok": true, "text": "..." }`           |
| `audio.transcribe` | `modelPath`, `audioPath`, `language?`     | **Swift:** **Qwen3-ASR** folders only (native via mlx-audio-swift). **Whisper** / other → `ok:false` so Python mlx-audio can run if enabled. |
| `audio.synthesize` | `modelPath`, `text`, `voice?`, `instruct?`, `languageCode?`, `referenceAudioPath?`, `referenceText?`, `max_tokens?`, `temperature?` | **Swift:** **Qwen3-TTS** only; WAV to temp path in `outputAudioPath`. Other TTS checkpoints → `ok:false` for Python fallback. |
| `image.generate`   | `modelPath`, `prompt`, …                  | stub in Swift; add `mflux-generate` / process policy later |

Errors: `{ "ok": false, "error": "message" }`.

`lm.generate` loads weights from the **local** directory at `modelPath` (same layout as Hugging Face / MLX downloads), caches the `ModelContainer` per path, and runs `ChatSession.respond`. If `imagePath` is set, the image is passed for **VLM** flows.

## App requirements

- **macOS 14+** (aligned with mlx-swift-lm 3.31.3).
- **Swift Package Manager** enabled for the app (`flutter` → `config` → `enable-swift-package-manager: true`).  
- Runner must list **FlmMLXRuntime** under **Frameworks, Libraries, and Embedded Content** (see `local_models_studio` `project.pbxproj`).

Other apps that depend on `local_models_flutter` must link the same **FlmMLXRuntime** package (or another binary that exports `flm_dispatch_json`) or native **LM / image** calls will fail symbol lookup until you add a process backend for those ops.

### Environment variables

| Variable | Effect |
|----------|--------|
| `FLM_MLX_PYTHON` | Python executable for **mlx-audio** fallback (default `python3`). |
| `FLM_DISABLE_PROCESS_FALLBACK` | If `1`, never run Python; only Swift (macOS) or stub errors (other OS). |
| `FLM_PROCESS_MLX_ONLY` | If `1`, use **only** Python for `audio.*` (no Swift attempt). |

## Python

[MLX-Audio](https://github.com/Blaizzy/mlx-audio) **Python** is a **transitional, optional** path for ASR/TTS when native code is missing or returns an error. It is **not** bundled in the Flutter app. Long-term, **macOS and other platforms should satisfy `audio.*` (and other ops) natively**; Python remains available for developers and power users who opt in.

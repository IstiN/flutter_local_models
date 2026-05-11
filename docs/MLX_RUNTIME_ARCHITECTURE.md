# Native MLX runtime architecture (Flutter → FFI → macOS)

## Goal

- **macOS:** run models through **native MLX** (Swift / `mlx-swift-lm`) exposed to Dart via **FFI**, not via a Python subprocess.
- **Mobile (later):** same Dart **interfaces** can be backed by Core ML, LiteRT, cloud, etc., without `dart:ffi` into MLX.

## Layers

1. **Dart (`local_models_flutter`)**  
   - `LmEngine`, `AudioEngine`, `ImageEngine` — small async APIs used by `LocalChatRunner`, `LocalAudioRunner`, `LocalImageRunner`.  
   - `FlmNativeDispatcher.invoke(op, payload)` — one C entry point `flm_dispatch_json(operation, json)` → JSON result.

2. **macOS plugin (`LocalModelsFlutterPlugin.swift`)**  
   - Implements `flm_dispatch_json` and routes `operation` to MLX codepaths as they land.  
   - Today: returns structured `{ "ok": false, "error": "..." }` until `mlx-swift-lm` is wired.

3. **Reference implementations**

   - **Apple / MLX:** [ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) — load LLMs/VLMs from hub or disk, `ChatSession`, etc.  
   - **Cross‑platform Gemma-style:** [DenisovAV/flutter_gemma](https://github.com/DenisovAV/flutter_gemma) / LiteRT — useful pattern for **iOS/Android** with a different native backend behind the same Dart API.

## Operations (contract)

| `operation`        | Payload (summary)                          | Success response                          |
|--------------------|---------------------------------------------|-------------------------------------------|
| `lm.generate`      | `modelPath`, `adapter`, `prompt`, `maxTokens`, `temperature`, `topP`, `enableThinking`, optional `audioPath` / `imagePath` | `{ "ok": true, "text": "..." }`           |
| `audio.transcribe` | `modelPath`, `audioPath`, `language?`     | `{ "ok": true, "text": "..." }`           |
| `audio.synthesize` | `modelPath`, `text`, TTS options map       | `{ "ok": true, "outputAudioPath": "..." }` |
| `image.generate`   | `modelPath`, `prompt`, size/step fields    | `{ "ok": true, "outputImagePath": "..." }` |

Errors: `{ "ok": false, "error": "message" }`.

## Integrating `mlx-swift-lm` (next steps)

1. Add Swift package to the **macOS Runner** target (or the plugin target), e.g.  
   `.package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3")`, plus a tokenizer/downloader integration per [their docs](https://github.com/ml-explore/mlx-swift-lm/blob/main/README.md).
2. Implement `lm.generate` by loading a **local** MLX model directory (same layout as current downloads) and running generation; map `RuntimeAdapter.mlxLm` / `mlxVlm` to the right Swift loader.
3. Replace stub errors in `flm_dispatch_json` with real calls; keep JSON contract stable for Dart.
4. Optional: stream tokens via a second operation or outbound callback channel — v1 can return full text only.

## Python

The previous `python -m mlx_lm` / `mlx_audio` subprocess path has been **removed** from this package. Reintroducing it would be a separate optional backend, not the default.

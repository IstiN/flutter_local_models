# Local Model Benchmark Report

Generated: `2026-05-11T14:50:52.380844+00:00`

## Environment

- macOS: `26.3.1`
- CPU: `Apple M5`
- Memory: `24 GB`
- MLX Python: `/Users/uladzimir_klyshevich/.venvs/mlx/bin/python`

## Method

- Chat: two short prompts, measured as cold request + immediate second request.
- TTS: two short synthesis requests, checks that an audio artifact is actually created.
- ASR: one transcription request using a generated Kokoro reference clip.
- Image: one 512×512 smoke prompt with steps capped at 1 to avoid multi-hour runs.
- Speed: chat uses output characters/sec; audio uses real-time factor (`RTF`, lower is better); image uses seconds/image.
- The current app uses process-per-request runners; the second run mainly benefits from OS/page cache, not a persistent resident model.

## Summary

| Model | Task | Size | Status | Cold / Run 1 | Second / Run 2 | Speed | Output |
|---|---:|---:|---|---:|---:|---:|---|
| Dia 1.6B 4bit | text_to_speech | 3 GB | passed | 27.4s | 1m 12s | RTF 7.75 | speech-1778504633483.wav (805.2 KB, 9.3s audio) |
| FLUX.1 Schnell mflux 4bit | image_generation | 9 GB | failed | 4.0s | — | — | exit code 1; ValueError: Error parsing line b'\x0e' in /Users/uladzimir_klyshevich/Library/Containers/com.example.localModelsStudio/Data/Library/Application Support/flutter_local_… |
| Gemma 4 31B IT 4bit | chat | 17.2 GB | timeout | 2m 37s | 2m 32s | — | timed out after 60s |
| Gemma 4 E2B IT 4bit | chat | 3.4 GB | passed | 14.6s | 10.5s | 8.1 chars/s | Локальный ИИ нужен для сохранения конфиденциальности и обеспечения автономной работы. |
| Kokoro 82M 4bit | text_to_speech | 641.1 MB | passed | 6.6s | 4.7s | RTF 1.75 | speech-1778505052449.wav (125.4 KB, 2.7s audio) |
| Qwen Image 2512 4bit | image_generation | 24.1 GB | timeout | 3m 1s | — | — | timed out after 180s |
| Qwen3 8B 4bit | chat | 4.3 GB | passed | 7.0s | 5.9s | 15.5 chars/s | <think> Хорошо, мне нужно ответить на вопрос "зачем нужен локальный ИИ?" одним коротким рус |
| Qwen3 ASR 0.6B 4bit | speech_to_text | 679.8 MB | passed | 3.6s | — | RTF 0.70 | Hello, this is a reusable reference voice sample for local model tests. |
| Qwen3 TTS 12Hz 0.6B Base 4bit | text_to_speech | 1.6 GB | passed | 5.4s | 4.9s | RTF 2.11 | speech-1778505260616.wav (108.8 KB, 2.3s audio) |
| Qwen3 TTS 12Hz 1.7B Base 4bit | text_to_speech | 2.2 GB | passed | 5.7s | 5.8s | RTF 2.43 | speech-1778505271189.wav (112.5 KB, 2.4s audio) |
| Qwen3 TTS 12Hz 1.7B VoiceDesign 4bit | text_to_speech | 2.2 GB | passed | 4.6s | 3.7s | RTF 1.78 | speech-1778505281596.wav (97.5 KB, 2.1s audio) |
| VibeVoice Realtime 0.5B 4bit | text_to_speech | 698.7 MB | passed | 7.0s | 6.2s | RTF 1.37 | speech-1778505292264.wav (212.5 KB, 4.5s audio) |
| VoxCPM2 4bit | text_to_speech | 2.1 GB | passed | 5.5s | 3.5s | RTF 1.56 | speech-1778511048878.wav (210.1 KB, 2.2s audio) |
| Z-Image Turbo mflux 4bit | image_generation | 5.5 GB | passed | 18.1s | — | 18.1s/image | image.png (226.9 KB) |

## Highlights

- Passed: `11/14` benchmark tasks.
- Fastest chat throughput: `Qwen3 8B 4bit` at `24.3 chars/s`.
- Best TTS RTF: `VibeVoice Realtime 0.5B 4bit` at `RTF 1.14` (`7.0s` wall time).
- ASR smoke test: `Qwen3 ASR 0.6B 4bit` at `RTF 0.70`.
- Fastest image smoke test: `Z-Image Turbo mflux 4bit` at `18.1s/image`.

## Failures / Skips

- **FLUX.1 Schnell mflux 4bit / image_generation**: `failed` — exit code 1; ValueError: Error parsing line b'\x0e' in /Users/uladzimir_klyshevich/Library/Containers/com.example.localModelsStudio/Data/Library/Application Support/flutter_local_models/models/flux1-schnell-mflux-4bit/tokenizer_2/spiece.model
- **Gemma 4 31B IT 4bit / chat**: `timeout` — timed out after 60s
- **Qwen Image 2512 4bit / image_generation**: `timeout` — timed out after 180s

## Raw Artifacts

- JSON: `benchmarks/local-model-benchmark-20260511-161518.json`

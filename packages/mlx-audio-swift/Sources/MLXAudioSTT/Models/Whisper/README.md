# Whisper

Native MLX Whisper ASR for `MLXAudioSTT`.

```swift
let model = try await WhisperASRModel.fromModelDirectory(modelURL)
let (_, audio) = try loadAudioArray(from: audioURL, sampleRate: model.sampleRate)
let output = model.generate(audio: audio)
print(output.text)
```

The implementation loads local Hugging Face / mlx-audio Whisper checkpoints, computes Whisper log-mel features, and performs greedy decoding with language token support.

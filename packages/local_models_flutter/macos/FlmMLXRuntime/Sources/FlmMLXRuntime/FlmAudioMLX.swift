import Foundation
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioSTT
import MLXAudioTTS

// MARK: - JSON helpers (payload from Dart)

private func intFromAny(_ value: Any?) -> Int? {
    if let v = value as? Int { return v }
    if let v = value as? Int64 { return Int(v) }
    if let n = value as? NSNumber { return n.intValue }
    if let d = value as? Double { return Int(d) }
    return nil
}

private func floatFromAny(_ value: Any?) -> Float? {
    if let v = value as? Float { return v }
    if let v = value as? Double { return Float(v) }
    if let n = value as? NSNumber { return n.floatValue }
    return nil
}

private func stringFromAny(_ value: Any?) -> String? {
    (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Config detection (local HF-style folders)

private func readConfigObject(modelDir: URL) -> [String: Any]? {
    let path = modelDir.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return obj
}

private func isWhisperASR(modelDir: URL) -> Bool {
    guard let obj = readConfigObject(modelDir: modelDir) else { return false }
    if let mt = obj["model_type"] as? String, mt.lowercased().contains("whisper") {
        return true
    }
    if let arch = obj["architectures"] as? [String] {
        return arch.contains { $0.localizedCaseInsensitiveContains("whisper") }
    }
    return false
}

private func isQwen3ASR(modelDir: URL) -> Bool {
    guard let obj = readConfigObject(modelDir: modelDir) else { return false }
    if let mt = obj["model_type"] as? String, mt == "qwen3_asr" {
        return true
    }
    if let arch = obj["architectures"] as? [String] {
        return arch.contains {
            $0.localizedCaseInsensitiveContains("qwen3") && $0.localizedCaseInsensitiveContains("asr")
        }
    }
    return false
}

private func isQwen3TTS(modelDir: URL) -> Bool {
    guard let obj = readConfigObject(modelDir: modelDir) else { return false }
    if let mt = obj["model_type"] as? String, mt == "qwen3_tts" {
        return true
    }
    if let arch = obj["architectures"] as? [String] {
        return arch.contains { $0.localizedCaseInsensitiveContains("qwen3") && $0.localizedCaseInsensitiveContains("tts") }
    }
    return false
}

private func isVibeVoiceStreamingTTS(modelDir: URL) -> Bool {
    guard let obj = readConfigObject(modelDir: modelDir) else { return false }
    if let mt = obj["model_type"] as? String, mt == "vibevoice_streaming" {
        return true
    }
    if let arch = obj["architectures"] as? [String] {
        return arch.contains { $0.localizedCaseInsensitiveContains("vibevoice") }
    }
    return false
}

private func isVibeVoiceASR(modelDir: URL) -> Bool {
    guard let obj = readConfigObject(modelDir: modelDir) else { return false }
    if let mt = obj["model_type"] as? String, mt == "vibevoice_asr" {
        return true
    }
    // Also detect via acoustic_tokenizer sub-config
    if let acousticCfg = obj["acoustic_tokenizer_config"] as? [String: Any],
       let mt = acousticCfg["model_type"] as? String,
       mt == "vibevoice_acoustic_tokenizer" {
        return true
    }
    return false
}

private func isGemma4WithAudio(modelDir: URL) -> Bool {
    guard let obj = readConfigObject(modelDir: modelDir) else { return false }
    if let mt = obj["model_type"] as? String, mt == "gemma4" {
        return obj["audio_token_id"] != nil || obj["audio_config"] != nil
    }
    return false
}

// MARK: - Language hints for Qwen3 ASR

private let asrLanguageHints: [String: String] = [
    "auto": "",
    "zh": "Chinese",
    "chinese": "Chinese",
    "en": "English",
    "english": "English",
    "ru": "Russian",
    "russian": "Russian",
    "de": "German",
    "german": "German",
    "es": "Spanish",
    "spanish": "Spanish",
    "fr": "French",
    "french": "French",
    "it": "Italian",
    "italian": "Italian",
    "pt": "Portuguese",
    "portuguese": "Portuguese",
    "ko": "Korean",
    "korean": "Korean",
    "ja": "Japanese",
    "japanese": "Japanese",
]

private func normalizedAsrLanguage(_ raw: String?) -> String? {
    guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else {
        return nil
    }
    if s == "auto" { return nil }
    if let mapped = asrLanguageHints[s], !mapped.isEmpty { return mapped }
    return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Language hints for Qwen3 TTS

private let ttsLanguageHints: [String: String] = [
    "auto": "",
    "zh": "Chinese",
    "chinese": "Chinese",
    "en": "English",
    "english": "English",
    "ru": "Russian",
    "russian": "Russian",
    "de": "German",
    "german": "German",
    "es": "Spanish",
    "spanish": "Spanish",
    "fr": "French",
    "french": "French",
    "it": "Italian",
    "italian": "Italian",
    "pt": "Portuguese",
    "portuguese": "Portuguese",
    "ko": "Korean",
    "korean": "Korean",
    "ja": "Japanese",
    "japanese": "Japanese",
]

private func normalizedTtsLanguage(_ raw: String?) -> String? {
    guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else {
        return nil
    }
    if s == "auto" { return nil }
    if let mapped = ttsLanguageHints[s], !mapped.isEmpty { return mapped }
    return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Qwen3 ASR/TTS (single actor: MLX models are not Sendable)

private actor FlmQwenMLXRuntime {
    static let shared = FlmQwenMLXRuntime()

    private var asrModels: [String: Qwen3ASRModel] = [:]
    private var ttsModels: [String: Qwen3TTSModel] = [:]

    func transcribe(
        modelPath: String,
        audioURL: URL,
        language: String?
    ) async throws -> String {
        let model: Qwen3ASRModel
        if let cached = asrModels[modelPath] {
            model = cached
        } else {
            let loaded = try await Qwen3ASRModel.fromModelDirectory(URL(fileURLWithPath: modelPath))
            asrModels[modelPath] = loaded
            model = loaded
        }

        let (_, audioMLX) = try loadAudioArray(from: audioURL, sampleRate: model.sampleRate)
        let lang = normalizedAsrLanguage(language)
        let base = model.defaultGenerationParameters
        let sttParams = STTGenerateParameters(
            maxTokens: base.maxTokens,
            temperature: base.temperature,
            topP: base.topP,
            topK: base.topK,
            verbose: base.verbose,
            language: lang,
            chunkDuration: base.chunkDuration,
            minChunkDuration: base.minChunkDuration,
            repetitionPenalty: base.repetitionPenalty,
            repetitionContextSize: base.repetitionContextSize
        )
        let output = model.generate(audio: audioMLX, generationParameters: sttParams)
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func synthesize(
        modelPath: String,
        text: String,
        maxTokensOverride: Int?,
        temperatureOverride: Float?,
        voiceParam: String?,
        referenceAudioPath: String?,
        refText: String?,
        language: String?
    ) async throws -> URL {
        let model: Qwen3TTSModel
        if let cached = ttsModels[modelPath] {
            model = cached
        } else {
            let loaded = try await Qwen3TTSModel.fromModelDirectory(URL(fileURLWithPath: modelPath))
            ttsModels[modelPath] = loaded
            model = loaded
        }

        var genParams = model.defaultGenerationParameters
        if let mt = maxTokensOverride {
            genParams.maxTokens = mt
        }
        if let t = temperatureOverride {
            genParams.temperature = t
        }

        var refAudioMLX: MLXArray?
        if let refPath = referenceAudioPath, !refPath.isEmpty, let rt = refText, !rt.isEmpty {
            let (_, arr) = try loadAudioArray(from: URL(fileURLWithPath: refPath))
            refAudioMLX = arr
        }

        let audioOut = try await model.generate(
            text: text,
            voice: voiceParam,
            refAudio: refAudioMLX,
            refText: refText,
            language: language,
            generationParameters: genParams
        )

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flm-tts-\(UUID().uuidString).wav")
        let samples = audioOut.asArray(Float.self)
        try AudioUtils.writeWavFile(
            samples: samples,
            sampleRate: Double(model.sampleRate),
            fileURL: outURL
        )
        return outURL
    }
}

// MARK: - Public entry points

enum FlmAudioMLX {
    static func transcribe(payload: [String: Any]) async -> [String: Any] {
        guard let modelPath = stringFromAny(payload["modelPath"]) else {
            return ["ok": false, "error": "missing modelPath"]
        }
        guard let audioPath = stringFromAny(payload["audioPath"]) else {
            return ["ok": false, "error": "missing audioPath"]
        }
        let modelDir = URL(fileURLWithPath: modelPath)
        let audioURL = URL(fileURLWithPath: audioPath)

        guard FileManager.default.fileExists(atPath: modelPath) else {
            return ["ok": false, "error": "Model directory does not exist: \(modelPath)"]
        }
        guard FileManager.default.fileExists(atPath: audioPath) else {
            return ["ok": false, "error": "audio file missing: \(audioPath)"]
        }

        if isWhisperASR(modelDir: modelDir) {
            return [
                "ok": false,
                "error":
                    "Whisper ASR is not implemented in the Swift runtime. Use Python mlx-audio (fallback) "
                    + "or install a Qwen3-ASR checkpoint for native transcription.",
            ]
        }

        if isVibeVoiceASR(modelDir: modelDir) {
            return [
                "ok": false,
                "error":
                    "VibeVoice ASR (vibevoice_asr) requires Python mlx-audio. "
                    + "Using process fallback (python3 -m mlx_audio.stt.generate).",
            ]
        }

        if isGemma4WithAudio(modelDir: modelDir) {
            do {
                let maxTok = intFromAny(payload["max_tokens"]) ?? 256
                let text = try await FlmGemma4ASRBridge.transcribe(
                    modelPath: modelPath,
                    audioURL: audioURL,
                    language: payload["language"] as? String,
                    maxTokens: maxTok
                )
                if text.isEmpty {
                    return ["ok": false, "error": "Gemma4 ASR returned an empty transcript"]
                }
                return ["ok": true, "text": text]
            } catch {
                return ["ok": false, "error": String(describing: error)]
            }
        }

        if !isQwen3ASR(modelDir: modelDir) {
            return [
                "ok": false,
                "error":
                    "This ASR folder is not a supported native Swift model (expected Qwen3-ASR). "
                    + "Use Python mlx-audio or a Qwen3-ASR install.",
            ]
        }

        do {
            let text = try await FlmQwenMLXRuntime.shared.transcribe(
                modelPath: modelPath,
                audioURL: audioURL,
                language: payload["language"] as? String
            )
            if text.isEmpty {
                return ["ok": false, "error": "Qwen3 ASR returned an empty transcript"]
            }
            return ["ok": true, "text": text]
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    static func synthesize(payload: [String: Any]) async -> [String: Any] {
        guard let modelPath = stringFromAny(payload["modelPath"]) else {
            return ["ok": false, "error": "missing modelPath"]
        }
        guard let text = stringFromAny(payload["text"]) else {
            return ["ok": false, "error": "missing text"]
        }

        let modelDir = URL(fileURLWithPath: modelPath)
        guard FileManager.default.fileExists(atPath: modelPath) else {
            return ["ok": false, "error": "Model directory does not exist: \(modelPath)"]
        }

        if isVibeVoiceStreamingTTS(modelDir: modelDir) {
            return [
                "ok": false,
                "error":
                    "VibeVoice Realtime TTS (vibevoice_streaming) requires Python mlx-audio. "
                    + "Using process fallback (python3 -m mlx_audio.tts.generate).",
            ]
        }

        if !isQwen3TTS(modelDir: modelDir) {
            return [
                "ok": false,
                "error":
                    "This TTS checkpoint is not implemented in the Swift runtime (native path supports Qwen3-TTS). "
                    + "Use Python mlx-audio fallback for other architectures.",
            ]
        }

        let refAudioPath = stringFromAny(payload["referenceAudioPath"])
        let refText = stringFromAny(payload["referenceText"])
        if (refAudioPath != nil) != (refText != nil) {
            return [
                "ok": false,
                "error": "Voice cloning requires both referenceAudioPath and referenceText (or neither).",
            ]
        }
        if let p = refAudioPath, !p.isEmpty {
            guard FileManager.default.fileExists(atPath: p) else {
                return ["ok": false, "error": "reference audio missing: \(p)"]
            }
        }

        do {
        let instruct = stringFromAny(payload["instruct"])
        let voiceName = stringFromAny(payload["voice"])
        // If `voice` is set it is a speaker-preset name (CustomVoice/Base).
        // If only `instruct` is set it is a VoiceDesign/emotion prompt.
        // The Dart layer clears `voice` for VoiceDesign models so this
        // priority is now correct.
        let voiceParam: String?
        if let voiceName, !voiceName.isEmpty {
            voiceParam = voiceName
        } else if let instruct, !instruct.isEmpty {
            voiceParam = instruct
        } else {
            voiceParam = nil
        }

        let langCode = payload["languageCode"] as? String
        let language = normalizedTtsLanguage(langCode)

        NSLog("[FlmTTS] voice=%@ instruct=%@ voiceParam=%@ lang=%@ refPath=%@",
              voiceName ?? "<nil>",
              instruct ?? "<nil>",
              voiceParam ?? "<nil>",
              language ?? "<nil>",
              stringFromAny(payload["referenceAudioPath"]) ?? "<nil>")

        let outURL = try await FlmQwenMLXRuntime.shared.synthesize(
                modelPath: modelPath,
                text: text,
                maxTokensOverride: intFromAny(payload["max_tokens"]),
                temperatureOverride: floatFromAny(payload["temperature"]),
                voiceParam: voiceParam,
                referenceAudioPath: refAudioPath,
                refText: refText,
                language: language
            )

            return ["ok": true, "outputAudioPath": outURL.path]
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }
}

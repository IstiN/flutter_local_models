import Foundation
@preconcurrency import MLX
import MLXAudioCore
import MLXHuggingFace
import MLXLMCommon
import MLXNN
import MLXVLM
import Tokenizers

/// Serializes Gemma 4 audio-tower MLX ops off Swift's cooperative executor.
private let flmGemma4AsrMlxQueue = DispatchQueue(label: "dev.flm.gemma4asr.mlx", qos: .userInitiated)
private enum FlmGemma4ASRError: Error {
    case notGemma4
    case missingAudioConfig
    case unexpectedPrepareResult
}

/// Native Gemma 4 speech-to-text: audio tower (MLX) + ``Gemma4/prepareAudioTranscription`` + greedy decode.
private actor FlmGemma4ASRRuntime {
    static let shared = FlmGemma4ASRRuntime()

    private var containers: [String: ModelContainer] = [:]
    private var weightCache: [String: [String: MLXArray]] = [:]

    private func modelContainer(modelPath: String) async throws -> ModelContainer {
        if let existing = containers[modelPath] {
            return existing
        }
        let loaded = try await loadModelContainer(
            from: URL(fileURLWithPath: modelPath),
            using: #huggingFaceTokenizerLoader()
        )
        containers[modelPath] = loaded
        return loaded
    }

    private func safetensors(modelPath: String) throws -> [String: MLXArray] {
        if let w = weightCache[modelPath] {
            return w
        }
        let url = URL(fileURLWithPath: modelPath).appendingPathComponent("model.safetensors")
        let w = try MLX.loadArrays(url: url)
        weightCache[modelPath] = w
        return w
    }

    func transcribe(
        modelPath: String,
        audioURL: URL,
        language: String?,
        maxTokens: Int
    ) async throws -> String {
        let container = try await modelContainer(modelPath: modelPath)

        let configURL = URL(fileURLWithPath: modelPath).appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configURL)
        let root = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
        guard let audioDict = root?["audio_config"] as? [String: Any] else {
            throw FlmGemma4ASRError.missingAudioConfig
        }
        let audioCfg = try FlmGemma4AudioTowerConfig(json: audioDict)
        let weights = try safetensors(modelPath: modelPath)

        let (_, audioMLX) = try loadAudioArray(from: audioURL, sampleRate: FlmGemma4Mel.sampleRate)
        var samples = audioMLX.asArray(Float.self)
        let cap = 30 * FlmGemma4Mel.sampleRate
        if samples.count > cap {
            samples = Array(samples.prefix(cap))
        }

        let audioFeatures: MLXArray = try flmGemma4AsrMlxQueue.sync {
            let mel = FlmGemma4Mel.logMel(samples).asType(.bfloat16)
            let encoded = try FlmGemma4AudioTower.encode(mel: mel, weights: weights, config: audioCfg)
            eval(encoded)
            return encoded
        }

        var genParams = GenerateParameters()
        genParams.maxTokens = maxTokens
        genParams.temperature = 0
        let generateParameters = genParams

        return try await container.perform { ctx in
            guard let gemma = ctx.model as? Gemma4 else {
                throw FlmGemma4ASRError.notGemma4
            }

            let trimmedLang = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let promptBody: String
            if !trimmedLang.isEmpty, trimmedLang.lowercased() != "auto" {
                promptBody =
                    "Transcribe the following speech segment in \(trimmedLang) into \(trimmedLang) text. "
                    + "Output only the transcription, no extra text."
            } else {
                promptBody =
                    "Transcribe the following speech segment in its original language. "
                    + "Output only the transcription, no extra text."
            }

            let nAudio = audioFeatures.dim(1)
            let userContent = "\(promptBody)\n\(String(repeating: "<|audio|>", count: nAudio))"

            let messages: [Message] = [["role": "user", "content": userContent]]
            let tokenIds = try ctx.tokenizer.applyChatTemplate(
                messages: messages,
                tools: nil as [ToolSpec]?,
                additionalContext: ["enable_thinking": false]
            )

            let inputIds = MLXArray(tokenIds).expandedDimensions(axis: 0)

            let cache = gemma.newCache(parameters: generateParameters)
            let prep = try gemma.prepareAudioTranscription(
                inputIds: inputIds,
                audioFeatures: audioFeatures,
                cache: cache
            )
            let lmOut: LMOutput
            switch prep {
            case .logits(let o):
                lmOut = o
            default:
                throw FlmGemma4ASRError.unexpectedPrepareResult
            }
            eval(lmOut.logits)

            let sampler = ArgMaxSampler()
            func sampleOne(_ logits: MLXArray) -> MLXArray {
                sampler.sample(logits: logits[0..., -1, 0...])
            }

            var y = sampleOne(lmOut.logits)
            eval(y)

            let eos = ctx.tokenizer.eosTokenId ?? 1
            var out: [Int] = []

            for _ in 0 ..< maxTokens {
                let tid = y.item(Int.self)
                if tid == eos {
                    break
                }
                out.append(tid)
                let stepIn = LMInput.Text(tokens: y)
                let next = gemma(stepIn[text: .newAxis], cache: cache, state: nil as LMOutput.State?)
                eval(next.logits)
                y = sampleOne(next.logits)
                eval(y)
            }

            return ctx.tokenizer.decode(tokenIds: out, skipSpecialTokens: true)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }
    }
}

enum FlmGemma4ASRBridge {
    static func transcribe(
        modelPath: String,
        audioURL: URL,
        language: String?,
        maxTokens: Int
    ) async throws -> String {
        try await FlmGemma4ASRRuntime.shared.transcribe(
            modelPath: modelPath,
            audioURL: audioURL,
            language: language,
            maxTokens: maxTokens
        )
    }
}

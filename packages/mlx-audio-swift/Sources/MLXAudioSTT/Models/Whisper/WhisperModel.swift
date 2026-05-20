import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXLMCommon
import MLXNN
import Tokenizers

private struct WhisperAttentionCache {
    var keys: MLXArray?
    var values: MLXArray?
}

private struct WhisperDecoderLayerCache {
    var selfAttention = WhisperAttentionCache()
    var crossAttention = WhisperAttentionCache()
}

private struct WhisperDecoderKVCache {
    var layers: [WhisperDecoderLayerCache]
    var sequenceLength: Int

    init(layerCount: Int, sequenceLength: Int = 0) {
        self.layers = Array(repeating: WhisperDecoderLayerCache(), count: layerCount)
        self.sequenceLength = sequenceLength
    }
}

private func whisperSinusoids(length: Int, channels: Int) -> MLXArray {
    let half = channels / 2
    let logTimescaleIncrement = log(10_000.0) / Float(max(half - 1, 1))
    let invTimescales = MLX.exp(-logTimescaleIncrement * MLXArray(0..<half).asType(.float32))
    let scaledTime = MLXArray(0..<length).asType(.float32).expandedDimensions(axis: 1)
        * invTimescales.expandedDimensions(axis: 0)
    return MLX.concatenated([MLX.sin(scaledTime), MLX.cos(scaledTime)], axis: 1)
}

private func whisperAdditiveCausalMask(
    queryLength: Int,
    keyLength: Int,
    offset: Int,
    dtype: DType
) -> MLXArray {
    let rows = MLXArray((0..<queryLength).map(Int32.init)).expandedDimensions(axis: 1)
    let cols = MLXArray((0..<keyLength).map(Int32.init)).expandedDimensions(axis: 0)
    let allowed = cols .<= (rows + Int32(offset))
    let mask = MLX.where(allowed, MLXArray(0.0), MLXArray(-Float.infinity)).asType(dtype)
    return mask.expandedDimensions(axis: 0).expandedDimensions(axis: 0)
}

private final class WhisperMultiHeadAttention: Module {
    let stateSize: Int
    let headCount: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo(key: "query") var query: Linear
    @ModuleInfo(key: "key") var key: Linear
    @ModuleInfo(key: "value") var value: Linear
    @ModuleInfo(key: "out") var out: Linear

    init(stateSize: Int, headCount: Int) {
        self.stateSize = stateSize
        self.headCount = headCount
        self.headDim = stateSize / headCount
        self.scale = pow(Float(headDim), -0.25)
        self._query.wrappedValue = Linear(stateSize, stateSize)
        self._key.wrappedValue = Linear(stateSize, stateSize, bias: false)
        self._value.wrappedValue = Linear(stateSize, stateSize)
        self._out.wrappedValue = Linear(stateSize, stateSize)
    }

    func callAsFunction(
        _ x: MLXArray,
        xa: MLXArray? = nil,
        mask: MLXArray? = nil,
        cache: WhisperAttentionCache? = nil
    ) -> (MLXArray, WhisperAttentionCache) {
        let batchSize = x.shape[0]
        let queryLength = x.shape[1]

        let q = query(x)
        let kSource: MLXArray
        let vSource: MLXArray
        var nextCache = cache ?? WhisperAttentionCache()

        if let xa {
            if let cachedKeys = nextCache.keys, let cachedValues = nextCache.values {
                kSource = cachedKeys
                vSource = cachedValues
            } else {
                kSource = key(xa)
                vSource = value(xa)
                nextCache.keys = kSource
                nextCache.values = vSource
            }
        } else {
            let newKeys = key(x)
            let newValues = value(x)
            if let cachedKeys = nextCache.keys, let cachedValues = nextCache.values {
                kSource = MLX.concatenated([cachedKeys, newKeys], axis: 1)
                vSource = MLX.concatenated([cachedValues, newValues], axis: 1)
            } else {
                kSource = newKeys
                vSource = newValues
            }
            nextCache.keys = kSource
            nextCache.values = vSource
        }

        let keyLength = kSource.shape[1]
        let qHeads = q.reshaped([batchSize, queryLength, headCount, headDim]).transposed(0, 2, 1, 3) * scale
        let kHeads = kSource.reshaped([batchSize, keyLength, headCount, headDim]).transposed(0, 2, 1, 3) * scale
        let vHeads = vSource.reshaped([batchSize, keyLength, headCount, headDim]).transposed(0, 2, 1, 3)

        var scores = MLX.matmul(qHeads, kHeads.swappedAxes(-2, -1))
        if let mask {
            scores = scores + mask.asType(scores.dtype)
        }
        let weights = MLX.softmax(scores, axis: -1)
        let attended = MLX.matmul(weights, vHeads)
        let merged = attended.transposed(0, 2, 1, 3).reshaped([batchSize, queryLength, stateSize])
        return (out(merged), nextCache)
    }
}

private final class WhisperResidualAttentionBlock: Module {
    @ModuleInfo(key: "attn") var attn: WhisperMultiHeadAttention
    @ModuleInfo(key: "attn_ln") var attnLN: LayerNorm
    @ModuleInfo(key: "cross_attn") var crossAttn: WhisperMultiHeadAttention?
    @ModuleInfo(key: "cross_attn_ln") var crossAttnLN: LayerNorm?
    @ModuleInfo(key: "mlp1") var mlp1: Linear
    @ModuleInfo(key: "mlp2") var mlp2: Linear
    @ModuleInfo(key: "mlp_ln") var mlpLN: LayerNorm

    init(stateSize: Int, headCount: Int, ffDim: Int, hasCrossAttention: Bool) {
        self._attn.wrappedValue = WhisperMultiHeadAttention(stateSize: stateSize, headCount: headCount)
        self._attnLN.wrappedValue = LayerNorm(dimensions: stateSize)
        self._crossAttn.wrappedValue = hasCrossAttention
            ? WhisperMultiHeadAttention(stateSize: stateSize, headCount: headCount)
            : nil
        self._crossAttnLN.wrappedValue = hasCrossAttention ? LayerNorm(dimensions: stateSize) : nil
        self._mlp1.wrappedValue = Linear(stateSize, ffDim)
        self._mlp2.wrappedValue = Linear(ffDim, stateSize)
        self._mlpLN.wrappedValue = LayerNorm(dimensions: stateSize)
    }

    func callAsFunction(
        _ x: MLXArray,
        xa: MLXArray? = nil,
        mask: MLXArray? = nil,
        cache: WhisperDecoderLayerCache? = nil
    ) -> (MLXArray, WhisperDecoderLayerCache) {
        var nextCache = cache ?? WhisperDecoderLayerCache()
        let selfOut = attn(attnLN(x), mask: mask, cache: nextCache.selfAttention)
        var hidden = x + selfOut.0
        nextCache.selfAttention = selfOut.1

        if let crossAttn, let crossAttnLN, let xa {
            let crossOut = crossAttn(crossAttnLN(hidden), xa: xa, cache: nextCache.crossAttention)
            hidden = hidden + crossOut.0
            nextCache.crossAttention = crossOut.1
        }

        hidden = hidden + mlp2(gelu(mlp1(mlpLN(hidden))))
        return (hidden, nextCache)
    }
}

private final class WhisperAudioEncoder: Module {
    let positionalEmbedding: MLXArray

    @ModuleInfo(key: "conv1") var conv1: Conv1d
    @ModuleInfo(key: "conv2") var conv2: Conv1d
    @ModuleInfo(key: "blocks") var blocks: [WhisperResidualAttentionBlock]
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm

    init(config: WhisperASRConfig) {
        self.positionalEmbedding = whisperSinusoids(length: config.maxSourcePositions, channels: config.dModel).asType(.float16)
        self._conv1.wrappedValue = Conv1d(
            inputChannels: config.numMelBins,
            outputChannels: config.dModel,
            kernelSize: 3,
            padding: 1
        )
        self._conv2.wrappedValue = Conv1d(
            inputChannels: config.dModel,
            outputChannels: config.dModel,
            kernelSize: 3,
            stride: 2,
            padding: 1
        )
        self._blocks.wrappedValue = (0..<config.encoderLayers).map { _ in
            WhisperResidualAttentionBlock(
                stateSize: config.dModel,
                headCount: config.encoderAttentionHeads,
                ffDim: config.encoderFfnDim,
                hasCrossAttention: false
            )
        }
        self._lnPost.wrappedValue = LayerNorm(dimensions: config.dModel)
    }

    func callAsFunction(_ mel: MLXArray) -> MLXArray {
        var hidden = gelu(conv1(mel))
        hidden = gelu(conv2(hidden))
        let seqLen = min(hidden.shape[1], positionalEmbedding.shape[0])
        hidden = hidden[0..., 0..<seqLen, 0...] + positionalEmbedding[0..<seqLen].asType(hidden.dtype)
        for block in blocks {
            hidden = block(hidden).0
        }
        return lnPost(hidden)
    }
}

private final class WhisperTextDecoder: Module {
    let maxTargetPositions: Int
    let hasSeparateProjection: Bool

    @ModuleInfo(key: "token_embedding") var tokenEmbedding: Embedding
    @ParameterInfo var positionalEmbedding: MLXArray
    @ModuleInfo(key: "blocks") var blocks: [WhisperResidualAttentionBlock]
    @ModuleInfo(key: "ln") var ln: LayerNorm
    @ModuleInfo(key: "proj_out") var projOut: Linear?

    init(config: WhisperASRConfig, hasSeparateProjection: Bool) {
        self.maxTargetPositions = config.maxTargetPositions
        self.hasSeparateProjection = hasSeparateProjection
        self._tokenEmbedding.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.dModel)
        self._positionalEmbedding.wrappedValue = MLX.zeros([config.maxTargetPositions, config.dModel], type: Float.self)
        self._blocks.wrappedValue = (0..<config.decoderLayers).map { _ in
            WhisperResidualAttentionBlock(
                stateSize: config.dModel,
                headCount: config.decoderAttentionHeads,
                ffDim: config.decoderFfnDim,
                hasCrossAttention: true
            )
        }
        self._ln.wrappedValue = LayerNorm(dimensions: config.dModel)
        self._projOut.wrappedValue = hasSeparateProjection ? Linear(config.dModel, config.vocabSize, bias: false) : nil
    }

    func callAsFunction(
        _ tokens: MLXArray,
        audioFeatures: MLXArray,
        cache: WhisperDecoderKVCache? = nil
    ) -> (MLXArray, WhisperDecoderKVCache) {
        let tokenCount = tokens.shape[1]
        let offset = cache?.sequenceLength ?? 0
        let positions = positionalEmbedding[offset..<(offset + tokenCount)].asType(tokenEmbedding.weight.dtype)
        var hidden = tokenEmbedding(tokens) + positions
        let mask = whisperAdditiveCausalMask(
            queryLength: tokenCount,
            keyLength: offset + tokenCount,
            offset: offset,
            dtype: hidden.dtype
        )

        var nextCache = cache ?? WhisperDecoderKVCache(layerCount: blocks.count, sequenceLength: 0)
        for (index, block) in blocks.enumerated() {
            let blockOut = block(hidden, xa: audioFeatures, mask: mask, cache: nextCache.layers[index])
            hidden = blockOut.0
            nextCache.layers[index] = blockOut.1
        }
        nextCache.sequenceLength = offset + tokenCount

        hidden = ln(hidden)
        if let projOut {
            return (projOut(hidden), nextCache)
        }
        return (tokenEmbedding.asLinear(hidden), nextCache)
    }
}

private final class WhisperModel: Module {
    @ModuleInfo(key: "encoder") var encoder: WhisperAudioEncoder
    @ModuleInfo(key: "decoder") var decoder: WhisperTextDecoder

    init(config: WhisperASRConfig, hasSeparateProjection: Bool) {
        self._encoder.wrappedValue = WhisperAudioEncoder(config: config)
        self._decoder.wrappedValue = WhisperTextDecoder(config: config, hasSeparateProjection: hasSeparateProjection)
    }
}

public final class WhisperASRModel: STTGenerationModel {
    public let sampleRate: Int
    public let config: WhisperASRConfig
    let featureConfig: WhisperFeatureExtractorConfig

    private let tokenizer: WhisperTokenizer
    private let model: WhisperModel
    private let suppressMask: MLXArray
    private let blankSuppressMask: MLXArray
    private let languageDetectMask: MLXArray

    private init(
        config: WhisperASRConfig,
        featureConfig: WhisperFeatureExtractorConfig,
        tokenizer: WhisperTokenizer,
        model: WhisperModel,
        suppressMask: MLXArray,
        blankSuppressMask: MLXArray,
        languageDetectMask: MLXArray
    ) {
        self.sampleRate = featureConfig.samplingRate
        self.config = config
        self.featureConfig = featureConfig
        self.tokenizer = tokenizer
        self.model = model
        self.suppressMask = suppressMask
        self.blankSuppressMask = blankSuppressMask
        self.languageDetectMask = languageDetectMask
    }

    public var defaultGenerationParameters: STTGenerateParameters {
        STTGenerateParameters(
            maxTokens: config.maxTargetPositions,
            temperature: 0.0,
            topP: 1.0,
            topK: 0,
            verbose: false,
            language: nil,
            chunkDuration: Float(featureConfig.chunkLength),
            minChunkDuration: 0.0
        )
    }

    public static func fromModelDirectory(_ modelDir: URL) async throws -> WhisperASRModel {
        let config = try WhisperASRConfig.load(from: modelDir)
        let featureConfig = try WhisperFeatureExtractorConfig.load(from: modelDir)
        let tokenizer = try await WhisperTokenizer.fromModelDirectory(modelDir, config: config)

        var weights: [String: MLXArray] = [:]
        let files = try FileManager.default.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "safetensors" {
            let shard = try MLX.loadArrays(url: file)
            weights.merge(shard) { _, new in new }
        }

        let hasSeparateProjection = weights["proj_out.weight"] != nil || weights["model.proj_out.weight"] != nil
        let model = WhisperModel(config: config, hasSeparateProjection: hasSeparateProjection)
        let sanitizedWeights = sanitize(weights: weights)

        if let quantization = config.quantization {
            quantize(model: model, groupSize: quantization.groupSize, bits: quantization.bits) { path, _ in
                sanitizedWeights["\(path).scales"] != nil
            }
        }

        try model.update(parameters: ModuleParameters.unflattened(sanitizedWeights), verify: .all)
        model.train(false)
        eval(model)

        return WhisperASRModel(
            config: config,
            featureConfig: featureConfig,
            tokenizer: tokenizer,
            model: model,
            suppressMask: MLXArray(tokenizer.suppressMask(vocabSize: config.vocabSize)).asType(.float32),
            blankSuppressMask: MLXArray(tokenizer.blankSuppressMask(vocabSize: config.vocabSize)).asType(.float32),
            languageDetectMask: MLXArray(tokenizer.detectLanguageTokenMask(vocabSize: config.vocabSize)).asType(.float32)
        )
    }

    public func generate(audio: MLXArray, generationParameters: STTGenerateParameters) -> STTOutput {
        let start = Date()
        let samples = whisperAudioSamples(audio)
        let chunkSize = WhisperAudioProcessor.samplesPerChunk(featureConfig: featureConfig)
        let chunks = WhisperAudioProcessor.chunked(samples: samples, chunkSize: chunkSize)

        var detectedLanguage = tokenizer.normalizeLanguage(generationParameters.language)
        var texts: [String] = []
        var segments: [[String: Any]] = []
        var totalGeneratedTokens = 0
        var totalPromptTokens = 0

        for chunk in chunks {
            let mel = WhisperAudioProcessor.logMelSpectrogram(
                samples: chunk.samples,
                featureConfig: featureConfig,
                maxSourcePositions: config.maxSourcePositions
            )
            let audioFeatures = model.encoder(mel)
            if detectedLanguage == nil {
                detectedLanguage = detectLanguage(audioFeatures: audioFeatures)
            }

            let decoded = decodeChunk(
                audioFeatures: audioFeatures,
                language: detectedLanguage,
                maxTokens: generationParameters.maxTokens
            )
            totalPromptTokens += decoded.promptTokenCount
            totalGeneratedTokens += decoded.generatedTokens.count

            let text = tokenizer.decode(tokens: decoded.generatedTokens)
            guard !text.isEmpty else { continue }
            texts.append(text)
            let startSec = Double(chunk.startSample) / Double(sampleRate)
            let endSec = Double(min(chunk.startSample + chunkSize, samples.count)) / Double(sampleRate)
            segments.append([
                "start": startSec,
                "end": endSec,
                "text": text,
            ])
        }

        let finalText = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let totalTime = Date().timeIntervalSince(start)
        let generationTps = totalTime > 0 ? Double(totalGeneratedTokens) / totalTime : 0

        return STTOutput(
            text: finalText,
            segments: segments.isEmpty ? nil : segments,
            language: detectedLanguage,
            promptTokens: totalPromptTokens,
            generationTokens: totalGeneratedTokens,
            totalTokens: totalPromptTokens + totalGeneratedTokens,
            promptTps: 0,
            generationTps: generationTps,
            totalTime: totalTime,
            peakMemoryUsage: 0
        )
    }

    public func generateStream(
        audio: MLXArray,
        generationParameters: STTGenerateParameters
    ) -> AsyncThrowingStream<STTGeneration, Error> {
        AsyncThrowingStream { continuation in
            let output = generate(audio: audio, generationParameters: generationParameters)
            if !output.text.isEmpty {
                continuation.yield(.token(output.text))
            }
            continuation.yield(.result(output))
            continuation.finish()
        }
    }

    private func detectLanguage(audioFeatures: MLXArray) -> String? {
        guard !tokenizer.allLanguageTokens.isEmpty else { return nil }
        let sot = MLXArray([Int32(tokenizer.sot)]).expandedDimensions(axis: 0)
        let logits = model.decoder(sot, audioFeatures: audioFeatures).0
        let last = logits[0, logits.shape[1] - 1, 0...].asType(.float32) + languageDetectMask
        let langID = last.argMax(axis: -1).item(Int.self)
        return tokenizer.allLanguageTokens.first(where: { $0.id == langID })?.code
    }

    private func decodeChunk(
        audioFeatures: MLXArray,
        language: String?,
        maxTokens: Int
    ) -> (generatedTokens: [Int], promptTokenCount: Int) {
        let initialTokens = tokenizer.initialTokens(language: language)
        var allTokens = initialTokens
        var cache: WhisperDecoderKVCache?
        var input = MLXArray(initialTokens.map(Int32.init)).expandedDimensions(axis: 0)
        let maxDecodeTokens = min(maxTokens, config.maxTargetPositions - initialTokens.count)

        for step in 0..<maxDecodeTokens {
            let decoded = model.decoder(input, audioFeatures: audioFeatures, cache: cache)
            cache = decoded.1
            var logits = decoded.0[0, decoded.0.shape[1] - 1, 0...].asType(.float32) + suppressMask
            if step == 0 {
                logits = logits + blankSuppressMask
            }
            let nextToken = logits.argMax(axis: -1).item(Int.self)
            if nextToken == tokenizer.eot {
                break
            }
            allTokens.append(nextToken)
            input = MLXArray([Int32(nextToken)]).expandedDimensions(axis: 0)
        }

        return (Array(allTokens.dropFirst(initialTokens.count)), initialTokens.count)
    }

    private func whisperAudioSamples(_ audio: MLXArray) -> [Float] {
        if audio.ndim == 1 {
            return audio.asType(.float32).asArray(Float.self)
        }
        return audio.reshaped([-1]).asType(.float32).asArray(Float.self)
    }

    private static func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        let keyMap: [(String, String?)] = [
            ("model.encoder.embed_positions.weight", nil),
            ("model.encoder.layer_norm.", "encoder.ln_post."),
            ("model.encoder.layers.", "encoder.blocks."),
            (".self_attn_layer_norm.", ".attn_ln."),
            (".final_layer_norm.", ".mlp_ln."),
            (".self_attn.q_proj.", ".attn.query."),
            (".self_attn.k_proj.", ".attn.key."),
            (".self_attn.v_proj.", ".attn.value."),
            (".self_attn.out_proj.", ".attn.out."),
            (".fc1.", ".mlp1."),
            (".fc2.", ".mlp2."),
            ("model.decoder.embed_tokens.", "decoder.token_embedding."),
            ("model.decoder.embed_positions.weight", "decoder.positional_embedding"),
            ("model.decoder.layer_norm.", "decoder.ln."),
            ("model.decoder.layers.", "decoder.blocks."),
            (".encoder_attn_layer_norm.", ".cross_attn_ln."),
            (".encoder_attn.q_proj.", ".cross_attn.query."),
            (".encoder_attn.k_proj.", ".cross_attn.key."),
            (".encoder_attn.v_proj.", ".cross_attn.value."),
            (".encoder_attn.out_proj.", ".cross_attn.out."),
        ]

        var sanitized: [String: MLXArray] = [:]
        let isHF = weights.keys.contains { $0.hasPrefix("model.") }

        for (rawKey, rawValue) in weights {
            var key = rawKey
            var value = rawValue

            if isHF {
                for (source, target) in keyMap {
                    guard key.contains(source) else { continue }
                    if let target {
                        key = key.replacingOccurrences(of: source, with: target)
                    } else {
                        key = ""
                    }
                    break
                }
                guard !key.isEmpty else { continue }
                if key.hasPrefix("model.") {
                    key = String(key.dropFirst("model.".count))
                }
                if rawKey == "proj_out.weight" || rawKey == "model.proj_out.weight" {
                    key = "decoder.proj_out.weight"
                }
                if (key == "encoder.conv1.weight" || key == "encoder.conv2.weight"), value.ndim == 3 {
                    value = value.transposed(0, 2, 1)
                }
            }

            if value.dtype.isFloatingPoint, value.dtype != .float16 {
                value = value.asType(.float16)
            }
            sanitized[key] = value
        }

        return sanitized
    }
}

import Foundation
import MLX
import MLXNN

/// Loads `audio_config` from the root `config.json` object.
struct FlmGemma4AudioTowerConfig: Sendable {
    let hiddenSize: Int
    let numHiddenLayers: Int
    let attentionChunkSize: Int
    let attentionContextLeft: Int
    let attentionContextRight: Int
    let numAttentionHeads: Int
    let attentionLogitCap: Float
    let convKernelSize: Int
    let gradientClipping: Float

    init(json audioConfig: [String: Any]) throws {
        func int(_ k: String) throws -> Int {
            if let v = audioConfig[k] as? Int { return v }
            if let n = audioConfig[k] as? NSNumber { return n.intValue }
            throw FlmGemma4AudioTowerError.badConfig("missing or invalid int: \(k)")
        }
        func float(_ k: String) throws -> Float {
            if let v = audioConfig[k] as? Float { return v }
            if let v = audioConfig[k] as? Double { return Float(v) }
            if let n = audioConfig[k] as? NSNumber { return n.floatValue }
            throw FlmGemma4AudioTowerError.badConfig("missing or invalid float: \(k)")
        }
        hiddenSize = try int("hidden_size")
        numHiddenLayers = try int("num_hidden_layers")
        attentionChunkSize = try int("attention_chunk_size")
        attentionContextLeft = try int("attention_context_left")
        attentionContextRight = try int("attention_context_right")
        numAttentionHeads = try int("num_attention_heads")
        attentionLogitCap = try float("attention_logit_cap")
        convKernelSize = try int("conv_kernel_size")
        gradientClipping = try float("gradient_clipping")
    }
}

enum FlmGemma4AudioTowerError: Error {
    case badConfig(String)
    case missingWeight(String)
}

/// Gemma 4 audio encoder (conformer tower) — ports ``gemma4_asr.py`` `encode_audio` / helpers.
enum FlmGemma4AudioTower {
    private static func stripPrefix(_ d: [String: MLXArray], _ prefix: String) -> [String: MLXArray] {
        var out: [String: MLXArray] = [:]
        out.reserveCapacity(d.count)
        for (k, v) in d where k.hasPrefix(prefix) {
            out[String(k.dropFirst(prefix.count))] = v
        }
        return out
    }

    private static func w(_ weights: [String: MLXArray], _ key: String) throws -> MLXArray {
        guard let v = weights[key] else { throw FlmGemma4AudioTowerError.missingWeight(key) }
        return v
    }

    private static func rmsNorm(_ x: MLXArray, weight: MLXArray?, eps: Float = 1e-6) -> MLXArray {
        if let weight {
            return MLXFast.rmsNorm(x, weight: weight, eps: eps)
        }
        return MLXFast.rmsNorm(x, weight: MLXArray.mlxNone, eps: eps)
    }

    /// `y = x @ Wᵀ` matching ``gemma4_asr.py`` `_clipped_linear` (`x @ w.T`).
    /// Weights may be `[out_features, in_features]` (HuggingFace) or
    /// `[in_features, out_features]` (some MLX exports) for non-square matrices.
    private static func matmulInputByLinearWeight(_ x: MLXArray, wMat: MLXArray) throws -> MLXArray {
        let inDim = Int(x.dim(-1))
        let shape = wMat.shape.map { Int($0) }
        guard shape.count == 2 else {
            throw FlmGemma4AudioTowerError.badConfig(
                "linear weight must be rank 2, got shape \(shape)"
            )
        }
        if shape[1] == inDim {
            return matmul(x, wMat.transposed(0, 1))
        }
        if shape[0] == inDim {
            return matmul(x, wMat)
        }
        throw FlmGemma4AudioTowerError.badConfig(
            "linear weight layout mismatch: x.lastDim=\(inDim) w.shape=\(shape)"
        )
    }

    /// Clipped affine: `y = clip(x) @ w.T` with optional IO clipping (Gemma4 clipped linear).
    private static func clippedLinear(
        _ x: MLXArray,
        weightKey: String,
        weights: [String: MLXArray]
    ) throws -> MLXArray {
        var t = x
        if weights.keys.contains("\(weightKey).input_min") {
            let lo = try w(weights, "\(weightKey).input_min").item(Float.self)
            let hi = try w(weights, "\(weightKey).input_max").item(Float.self)
            t = MLX.clip(t, min: MLXArray(lo), max: MLXArray(hi))
        }
        let wMat = try w(weights, "\(weightKey).linear.weight")
        var y = try matmulInputByLinearWeight(t, wMat: wMat)
        if weights.keys.contains("\(weightKey).output_min") {
            let lo = try w(weights, "\(weightKey).output_min").item(Float.self)
            let hi = try w(weights, "\(weightKey).output_max").item(Float.self)
            y = MLX.clip(y, min: MLXArray(lo), max: MLXArray(hi))
        }
        return y
    }

    private static func feedForward(_ x: MLXArray, _ W: [String: MLXArray], gradClip: Float) throws -> MLXArray {
        let gc = min(gradClip, Float.greatestFiniteMagnitude)
        var h = x
        let residual = h
        h = MLX.clip(h, min: MLXArray(-gc), max: MLXArray(gc))
        h = rmsNorm(h, weight: W["pre_layer_norm.weight"])
        h = try clippedLinear(h, weightKey: "ffw_layer_1", weights: W)
        h = silu(h)
        h = try clippedLinear(h, weightKey: "ffw_layer_2", weights: W)
        h = MLX.clip(h, min: MLXArray(-gc), max: MLXArray(gc))
        h = rmsNorm(h, weight: W["post_layer_norm.weight"])
        return h * MLXArray(0.5) + residual * MLXArray(0.5)
    }

    private static func relPosEnc(hiddenSize: Int, contextSize: Int, dtype: DType) -> MLXArray {
        let numTimescales = hiddenSize / 2
        let logTimescaleIncrement = log(10_000.0) / Float(max(numTimescales - 1, 1))
        var invTimescales: [Float] = []
        invTimescales.reserveCapacity(numTimescales)
        for i in 0 ..< numTimescales {
            invTimescales.append(exp(-Float(i) * logTimescaleIncrement))
        }
        let half = contextSize / 2
        let nrow = half + 1
        var sinCos: [Float] = []
        sinCos.reserveCapacity(nrow * hiddenSize)
        for p in stride(from: half, through: 0, by: -1) {
            let pf = Float(p)
            var sines: [Float] = []
            var cosines: [Float] = []
            sines.reserveCapacity(numTimescales)
            cosines.reserveCapacity(numTimescales)
            for i in 0 ..< numTimescales {
                let angle = pf * invTimescales[i]
                sines.append(sin(angle))
                cosines.append(cos(angle))
            }
            sinCos.append(contentsOf: sines)
            sinCos.append(contentsOf: cosines)
        }
        return MLXArray(sinCos, [1, nrow, hiddenSize]).asType(dtype)
    }

    private static func chunkedAttention(
        hidden: MLXArray,
        layerWeights: [String: MLXArray],
        positionEmbeddings: MLXArray,
        chunkSize: Int,
        contextLeft: Int,
        contextRight: Int,
        numHeads: Int,
        headDim: Int,
        softcap: Float,
        gradClip: Float
    ) throws -> MLXArray {
        let B = hidden.dim(0)
        let T = hidden.dim(1)
        let qScale = pow(Float(headDim), -0.5) / log(2)
        let kScale = log(1 + Float(Darwin.M_E)) / log(2)

        let maxPast = contextLeft - 1
        // Match `gemma4_asr.py`: local window length used inside attention.
        let contextSize = chunkSize + maxPast

        let perDimScale = try w(layerWeights, "self_attn.per_dim_scale")

        var q = try clippedLinear(hidden, weightKey: "self_attn.q_proj", weights: layerWeights)
        var k = try clippedLinear(hidden, weightKey: "self_attn.k_proj", weights: layerWeights)
        var v = try clippedLinear(hidden, weightKey: "self_attn.v_proj", weights: layerWeights)

        q = q.asType(.float32).reshaped(B, T, numHeads, headDim)
        k = k.asType(.float32).reshaped(B, T, numHeads, headDim)
        v = v.asType(.float32).reshaped(B, T, numHeads, headDim)

        q = q * (MLXArray(qScale) * softplus(perDimScale).asType(.float32))
        k = k * MLXArray(kScale)

        let numBlocks = (T + chunkSize - 1) / chunkSize
        let padLen = numBlocks * chunkSize - T

        func padTime(_ arr: MLXArray) -> MLXArray {
            guard padLen > 0 else { return arr }
            let rest = arr.shape.dropFirst().map { Int($0) }
            let padShape = [B, padLen] + rest
            let z = MLXArray.zeros(padShape, dtype: arr.dtype)
            return concatenated([arr, z], axis: 1)
        }

        let qPad = padTime(q)
        let kPad = padTime(k)
        let vPad = padTime(v)

        let qBlocks = qPad.reshaped(B, numBlocks, chunkSize, numHeads, headDim)

        let leftPadK = MLXArray.zeros([B, maxPast, numHeads, headDim], dtype: k.dtype)
        let rightPadK = MLXArray.zeros([B, chunkSize - 1, numHeads, headDim], dtype: k.dtype)
        let kPadded = concatenated([leftPadK, kPad, rightPadK], axis: 1)
        let vPadded = concatenated([leftPadK, vPad, rightPadK], axis: 1)

        var kCtxSlices: [MLXArray] = []
        var vCtxSlices: [MLXArray] = []
        kCtxSlices.reserveCapacity(numBlocks)
        vCtxSlices.reserveCapacity(numBlocks)
        for i in 0 ..< numBlocks {
            let start = i * chunkSize
            let end = start + contextSize
            kCtxSlices.append(kPadded[0..., start ..< end, 0..., 0...])
            vCtxSlices.append(vPadded[0..., start ..< end, 0..., 0...])
        }
        let kCtx = stacked(kCtxSlices, axis: 1)
        let vCtx = stacked(vCtxSlices, axis: 1)

        var relK = try clippedLinear(
            positionEmbeddings,
            weightKey: "self_attn.relative_k_proj",
            weights: layerWeights
        )
        relK = relK.reshaped(-1, numHeads, headDim)

        let qT = qBlocks.transposed(0, 3, 1, 2, 4)
        let kT = kCtx.transposed(0, 3, 1, 4, 2)
        let matrixAc = matmul(qT, kT)

        let qFlat = qT.reshaped(B, numHeads, numBlocks * chunkSize, headDim)
        let relKt = relK.transposed(1, 2, 0)
        let matrixBdFlat = matmul(qFlat, relKt)
        var matrixBd = matrixBdFlat.reshaped(B, numHeads, numBlocks, chunkSize, -1)

        let posLen = matrixBd.dim(-1)
        let padSize = contextSize + 1 - posLen
        if padSize > 0 {
            let shapeBd = matrixBd.shape.dropLast().map { Int($0) } + [padSize]
            let padBd = MLXArray.zeros(shapeBd, dtype: matrixBd.dtype)
            matrixBd = concatenated([matrixBd, padBd], axis: -1)
        }
        matrixBd = matrixBd.reshaped(B, numHeads, numBlocks, chunkSize * (contextSize + 1))
        let flatBd = chunkSize * contextSize
        matrixBd = matrixBd[.ellipsis, ..<flatBd]
        matrixBd = matrixBd.reshaped(B, numHeads, numBlocks, chunkSize, contextSize)

        var attnWeights = matrixAc + matrixBd
        attnWeights = tanh(attnWeights / MLXArray(softcap)) * MLXArray(softcap)
        attnWeights = softmax(attnWeights.asType(.float32), axis: -1).asType(v.dtype)

        let vT = vCtx.transposed(0, 3, 1, 2, 4)
        var out = matmul(attnWeights, vT)
        out = out.transposed(0, 2, 3, 1, 4)
        out = out.reshaped(B, numBlocks * chunkSize, numHeads * headDim)
        out = out[0..., 0 ..< T, 0...]

        out = out.asType(hidden.dtype)
        out = try clippedLinear(out, weightKey: "self_attn.post", weights: layerWeights)
        return out
    }

    private static func lightConv1d(
        _ x: MLXArray,
        layerWeights: [String: MLXArray],
        kernelSize: Int,
        gradClip: Float
    ) throws -> MLXArray {
        let gc = min(gradClip, Float.greatestFiniteMagnitude)
        let residual = x
        var h = x
        h = rmsNorm(h, weight: layerWeights["lconv1d.pre_layer_norm.weight"])
        h = try clippedLinear(h, weightKey: "lconv1d.linear_start", weights: layerWeights)
        let last = h.dim(-1)
        let half = last / 2
        let h1 = h[.ellipsis, ..<half]
        let h2 = h[.ellipsis, half...]
        h = h1 * sigmoid(h2)

        let dw = try w(layerWeights, "lconv1d.depthwise_conv1d.weight")
        let B = h.dim(0)
        let T = h.dim(1)
        let H = h.dim(2)
        let k = kernelSize
        _ = H
        let padArr = MLXArray.zeros([B, k - 1, H], dtype: h.dtype)
        let hPad = concatenated([padArr, h], axis: 1)

        var unfolded: [MLXArray] = []
        unfolded.reserveCapacity(T)
        for i in 0 ..< T {
            unfolded.append(hPad[0..., i ..< (i + k), 0...])
        }
        let xUnfolded = stacked(unfolded, axis: 1)
        let dw2d = dw[0..., 0..., 0].transposed(0, 1)
        var dwB = expandedDimensions(dw2d, axis: 0)
        dwB = expandedDimensions(dwB, axis: 0)
        h = (xUnfolded * dwB).sum(axis: 2)

        h = MLX.clip(h, min: MLXArray(-gc), max: MLXArray(gc))
        h = rmsNorm(h, weight: layerWeights["lconv1d.conv_norm.weight"])
        h = silu(h)
        h = try clippedLinear(h, weightKey: "lconv1d.linear_end", weights: layerWeights)
        return h + residual
    }

    private static func audioLayer(
        _ x: MLXArray,
        layerWeights: [String: MLXArray],
        cfg: FlmGemma4AudioTowerConfig,
        posEmb: MLXArray
    ) throws -> MLXArray {
        let gradCap = min(cfg.gradientClipping, Float.greatestFiniteMagnitude)
        let ff1 = stripPrefix(layerWeights, "feed_forward1.")
        var h = try feedForward(x, ff1, gradClip: gradCap)

        let residual = h
        h = MLX.clip(h, min: MLXArray(-gradCap), max: MLXArray(gradCap))
        h = rmsNorm(h, weight: layerWeights["norm_pre_attn.weight"])

        h = try chunkedAttention(
            hidden: h,
            layerWeights: layerWeights,
            positionEmbeddings: posEmb,
            chunkSize: cfg.attentionChunkSize,
            contextLeft: cfg.attentionContextLeft,
            contextRight: cfg.attentionContextRight,
            numHeads: cfg.numAttentionHeads,
            headDim: cfg.hiddenSize / cfg.numAttentionHeads,
            softcap: cfg.attentionLogitCap,
            gradClip: gradCap
        )

        h = MLX.clip(h, min: MLXArray(-gradCap), max: MLXArray(gradCap))
        h = rmsNorm(h, weight: layerWeights["norm_post_attn.weight"])
        h = h + residual

        h = try lightConv1d(h, layerWeights: layerWeights, kernelSize: cfg.convKernelSize, gradClip: gradCap)

        let ff2 = stripPrefix(layerWeights, "feed_forward2.")
        h = try feedForward(h, ff2, gradClip: gradCap)

        h = MLX.clip(h, min: MLXArray(-gradCap), max: MLXArray(gradCap))
        h = rmsNorm(h, weight: layerWeights["norm_out.weight"])
        return h
    }

    private static func subsampleConvProjection(mel: MLXArray, weights: [String: MLXArray]) throws -> MLXArray {
        let b = mel.dim(0)
        let t = mel.dim(1)
        let m = mel.dim(2)
        var x = mel.reshaped(b, t, m, 1)

        let w0 = try w(weights, "audio_tower.subsample_conv_projection.layer0.conv.weight")
        let norm0 = try w(weights, "audio_tower.subsample_conv_projection.layer0.norm.weight")
        x = conv2d(x, w0, stride: IntOrPair((2, 2)), padding: IntOrPair((1, 1)))
        x = MLXFast.rmsNorm(x, weight: norm0, eps: 1e-6)
        x = relu(x)

        let w1 = try w(weights, "audio_tower.subsample_conv_projection.layer1.conv.weight")
        let norm1 = try w(weights, "audio_tower.subsample_conv_projection.layer1.norm.weight")
        x = conv2d(x, w1, stride: IntOrPair((2, 2)), padding: IntOrPair((1, 1)))
        x = MLXFast.rmsNorm(x, weight: norm1, eps: 1e-6)
        x = relu(x)

        let b2 = x.dim(0)
        let t2 = x.dim(1)
        let w2 = x.dim(2)
        let c2 = x.dim(3)
        x = x.reshaped(b2, t2, w2 * c2)

        let wProj = try w(weights, "audio_tower.subsample_conv_projection.input_proj_linear.weight")
        x = try matmulInputByLinearWeight(x, wMat: wProj)
        return x
    }

    private static func embedAudio(hidden: MLXArray, weights: [String: MLXArray]) throws -> MLXArray {
        var x = rmsNorm(hidden, weight: nil)
        let wq = try w(weights, "embed_audio.embedding_projection.weight")
        let scales = try w(weights, "embed_audio.embedding_projection.scales")
        let biases = weights["embed_audio.embedding_projection.biases"]
        let outFeatures = wq.dim(0)
        let nGroups = scales.dim(1)
        let bits = 4
        let inFeatures = wq.dim(1) * (32 / bits)
        let groupSize = inFeatures / nGroups
        let wFp = dequantized(
            wq, scales: scales, biases: biases, groupSize: groupSize, bits: bits, mode: .affine,
            dtype: .bfloat16)
        _ = outFeatures
        x = try matmulInputByLinearWeight(x, wMat: wFp)
        return x
    }

    /// - Parameter mel: `[1, time, nMels]` (e.g. from ``FlmGemma4Mel/logMel``), any float dtype.
    static func encode(
        mel: MLXArray,
        weights: [String: MLXArray],
        config: FlmGemma4AudioTowerConfig
    ) throws -> MLXArray {
        let dtype = DType.bfloat16
        let melMx = mel.asType(dtype)

        var hidden = try subsampleConvProjection(mel: melMx, weights: weights)
        let contextSize =
            config.attentionChunkSize + config.attentionContextLeft - 1 + config.attentionContextRight
        let posEmb = relPosEnc(hiddenSize: config.hiddenSize, contextSize: contextSize, dtype: dtype)

        for layerIdx in 0 ..< config.numHiddenLayers {
            let prefix = "audio_tower.layers.\(layerIdx)."
            let layerW = stripPrefix(weights, prefix)
            hidden = try audioLayer(hidden, layerWeights: layerW, cfg: config, posEmb: posEmb)
            eval(hidden)
        }

        let outW = try w(weights, "audio_tower.output_proj.weight")
        let outB = try w(weights, "audio_tower.output_proj.bias")
        hidden = try matmulInputByLinearWeight(hidden, wMat: outW) + outB
        return try embedAudio(hidden: hidden, weights: weights)
    }
}

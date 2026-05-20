import Foundation
import MLX
import MLXAudioCore

struct WhisperFeatureExtractorConfig: Codable, Sendable {
    let chunkLength: Int
    let featureSize: Int
    let hopLength: Int
    let nFFT: Int
    let samplingRate: Int
    let melFilters: [[Float]]?

    enum CodingKeys: String, CodingKey {
        case chunkLength = "chunk_length"
        case featureSize = "feature_size"
        case hopLength = "hop_length"
        case nFFT = "n_fft"
        case samplingRate = "sampling_rate"
        case melFilters = "mel_filters"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.chunkLength = try container.decodeIfPresent(Int.self, forKey: .chunkLength) ?? 30
        self.featureSize = try container.decodeIfPresent(Int.self, forKey: .featureSize) ?? 80
        self.hopLength = try container.decodeIfPresent(Int.self, forKey: .hopLength) ?? 160
        self.nFFT = try container.decodeIfPresent(Int.self, forKey: .nFFT) ?? 400
        self.samplingRate = try container.decodeIfPresent(Int.self, forKey: .samplingRate) ?? 16_000
        self.melFilters = try container.decodeIfPresent([[Float]].self, forKey: .melFilters)
    }

    static func load(from modelDirectory: URL) throws -> WhisperFeatureExtractorConfig {
        let url = modelDirectory.appendingPathComponent("preprocessor_config.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

enum WhisperAudioProcessor {
    static func samplesPerChunk(featureConfig: WhisperFeatureExtractorConfig) -> Int {
        featureConfig.chunkLength * featureConfig.samplingRate
    }

    static func chunked(samples: [Float], chunkSize: Int) -> [(startSample: Int, samples: [Float])] {
        guard !samples.isEmpty else { return [(0, [])] }
        guard chunkSize > 0 else { return [(0, samples)] }

        var chunks: [(Int, [Float])] = []
        var start = 0
        while start < samples.count {
            let end = min(start + chunkSize, samples.count)
            chunks.append((start, Array(samples[start..<end])))
            start = end
        }
        return chunks
    }

    static func logMelSpectrogram(
        samples: [Float],
        featureConfig: WhisperFeatureExtractorConfig,
        maxSourcePositions: Int
    ) -> MLXArray {
        let targetSamples = samplesPerChunk(featureConfig: featureConfig)
        let padded = padOrTrim(samples, targetLength: targetSamples)
        let audio = MLXArray(padded).asType(.float32)
        let window = periodicHannWindow(size: featureConfig.nFFT)
        let paddedAudio = reflectPadCenter(audio, pad: featureConfig.nFFT / 2)

        let nFrames = 1 + max(0, (paddedAudio.shape[0] - featureConfig.nFFT) / featureConfig.hopLength)
        guard nFrames > 0 else {
            return MLXArray.zeros([1, maxSourcePositions * 2, featureConfig.featureSize], type: Float.self)
                .asType(.float16)
        }

        let frameIndex = asStrided(
            paddedAudio,
            [nFrames, featureConfig.nFFT],
            strides: [featureConfig.hopLength, 1],
            offset: 0
        )
        let frames = frameIndex * window.expandedDimensions(axis: 0)
        let spectrum = MLXFFT.rfft(frames, axis: -1)
        var magnitudes = MLX.abs(spectrum).square()

        if magnitudes.shape[0] > 0 {
            magnitudes = magnitudes[0..<(magnitudes.shape[0] - 1), 0...]
        }
        magnitudes = magnitudes.transposed(1, 0)

        let melFilters = melFilterbank(featureConfig: featureConfig)
        var melSpec = MLX.matmul(melFilters.transposed(1, 0), magnitudes)
        melSpec = MLX.maximum(melSpec, MLXArray(Float(1e-10)))

        var logSpec = MLX.log10(melSpec)
        let maxVal = logSpec.max()
        logSpec = MLX.maximum(logSpec, maxVal - MLXArray(Float(8.0)))
        logSpec = (logSpec + MLXArray(Float(4.0))) / MLXArray(Float(4.0))

        let framesCount = min(logSpec.shape[1], maxSourcePositions * 2)
        var timeMajor = logSpec[0..., 0..<framesCount].transposed(1, 0)
        if framesCount < maxSourcePositions * 2 {
            let pad = MLX.zeros([maxSourcePositions * 2 - framesCount, featureConfig.featureSize], type: Float.self)
            timeMajor = MLX.concatenated([timeMajor, pad], axis: 0)
        }
        return timeMajor.expandedDimensions(axis: 0).asType(.float16)
    }

    private static func melFilterbank(featureConfig: WhisperFeatureExtractorConfig) -> MLXArray {
        if let melFilters = featureConfig.melFilters, !melFilters.isEmpty {
            return MLXArray(melFilters.flatMap { $0 }).reshaped([melFilters.count, melFilters[0].count]).asType(.float32)
        }
        return melFilters(
            sampleRate: featureConfig.samplingRate,
            nFft: featureConfig.nFFT,
            nMels: featureConfig.featureSize,
            fMin: 0,
            fMax: Float(featureConfig.samplingRate) / 2.0,
            norm: "slaney",
            melScale: .slaney
        ).asType(.float32)
    }

    private static func padOrTrim(_ samples: [Float], targetLength: Int) -> [Float] {
        if samples.count == targetLength {
            return samples
        }
        if samples.count > targetLength {
            return Array(samples.prefix(targetLength))
        }
        return samples + Array(repeating: 0, count: targetLength - samples.count)
    }

    private static func periodicHannWindow(size: Int) -> MLXArray {
        let n = MLXArray(0..<size).asType(.float32)
        return 0.5 * (1.0 - MLX.cos((2.0 * Float.pi * n) / Float(size)))
    }

    private static func reflectPadCenter(_ audio: MLXArray, pad: Int) -> MLXArray {
        guard pad > 0 else { return audio.asType(.float32) }

        let samples = audio.asType(.float32).asArray(Float.self)
        guard !samples.isEmpty else {
            return MLXArray.zeros([2 * pad], type: Float.self)
        }

        func reflectIndex(_ idx: Int, count: Int) -> Int {
            if count <= 1 { return 0 }
            var i = idx
            while i < 0 || i >= count {
                if i < 0 {
                    i = -i
                } else {
                    i = 2 * count - i - 2
                }
            }
            return i
        }

        var output = [Float](repeating: 0, count: samples.count + 2 * pad)
        for i in 0..<output.count {
            output[i] = samples[reflectIndex(i - pad, count: samples.count)]
        }
        return MLXArray(output)
    }
}

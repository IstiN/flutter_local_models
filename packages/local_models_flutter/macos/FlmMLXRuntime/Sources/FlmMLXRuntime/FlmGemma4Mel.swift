import Foundation
import MLX

/// Log-mel features aligned with HuggingFace ``Gemma4AudioFeatureExtractor`` (HTK mel, periodic Hann).
enum FlmGemma4Mel {
    static let sampleRate = 16_000
    static let featureSize = 128
    static let frameLengthMs: Float = 20
    static let hopLengthMs: Float = 10
    static let minFrequency: Float = 0
    static let maxFrequency: Float = 8000
    static let melFloor: Float = 1e-3

    private static var frameLength: Int {
        Int((Float(sampleRate) * frameLengthMs / 1000.0).rounded())
    }

    private static var hopLength: Int {
        Int((Float(sampleRate) * hopLengthMs / 1000.0).rounded())
    }

    private static func optimalFFTLength(windowLength: Int) -> Int {
        1 << Int(ceil(log2(Double(windowLength))))
    }

    private static func hertzToMel(_ f: Float) -> Float {
        2595.0 * log10(1.0 + f / 700.0)
    }

    private static func melToHertz(_ m: Float) -> Float {
        700.0 * (pow(10, m / 2595.0) - 1.0)
    }

    private static func melFilterBank(numFreqBins: Int) -> MLXArray {
        let nMels = featureSize
        let melMin = hertzToMel(minFrequency)
        let melMax = hertzToMel(maxFrequency)
        var melFreqs = [Float](repeating: 0, count: nMels + 2)
        for i in 0 ..< (nMels + 2) {
            let t = Float(i) / Float(nMels + 1)
            melFreqs[i] = melMin * (1 - t) + melMax * t
        }
        let filterFreqs = melFreqs.map { melToHertz($0) }

        let nyq = Float(sampleRate) / 2.0
        let fftFreqs: [Float] = (0 ..< numFreqBins).map { i in
            nyq * Float(i) / Float(max(numFreqBins - 1, 1))
        }

        var bank = [Float](repeating: 0, count: numFreqBins * nMels)
        for m in 0 ..< nMels {
            let left = filterFreqs[m]
            let center = filterFreqs[m + 1]
            let right = filterFreqs[m + 2]
            for k in 0 ..< numFreqBins {
                let f = fftFreqs[k]
                var w: Float = 0
                if f > left && f < right {
                    if f < center {
                        w = (f - left) / max(center - left, 1e-10)
                    } else {
                        w = (right - f) / max(right - center, 1e-10)
                    }
                }
                bank[k * nMels + m] = w
            }
        }
        return MLXArray(bank, [numFreqBins, nMels])
    }

    private static func periodicHann(_ n: Int) -> MLXArray {
        var w = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            w[i] = 0.5 - 0.5 * cos(2.0 * Float.pi * Float(i) / Float(n))
        }
        return MLXArray(w, [n])
    }

    /// Mono float waveform (16 kHz, roughly [-1,1]) → `[1, frames, featureSize]` float32.
    static func logMel(_ samples: [Float]) -> MLXArray {
        let fl = frameLength
        let hop = hopLength
        let fftN = optimalFFTLength(windowLength: fl)
        let numBins = fftN / 2 + 1
        let padLeft = fl / 2

        var wavePadded = [Float](repeating: 0, count: padLeft + max(samples.count, 0))
        if !samples.isEmpty {
            for i in 0 ..< samples.count {
                wavePadded[padLeft + i] = samples[i]
            }
        }

        let slen = wavePadded.count
        let frameSizeForUnfold = fl + 1
        guard slen >= frameSizeForUnfold else {
            return MLX.zeros([1, 0, featureSize], dtype: .float32)
        }

        var windowRows: [MLXArray] = []
        var start = 0
        while start + frameSizeForUnfold <= slen {
            let chunk = Array(wavePadded[start ..< start + frameSizeForUnfold])
            let trimmed = Array(chunk.prefix(fl))
            windowRows.append(MLXArray(trimmed, [fl]))
            start += hop
        }

        let win = periodicHann(fl)
        let melW = melFilterBank(numFreqBins: numBins)

        var framed = stacked(windowRows, axis: 0)
        framed = framed * win
        framed = padded(framed, widths: [IntOrPair((0, 0)), IntOrPair((0, fftN - fl))])
        let spectrum = rfft(framed, n: fftN, axis: -1)
        let mag = abs(spectrum)
        var mel = mag.matmul(melW)
        mel = log(mel + MLXArray(melFloor))
        mel = expandedDimensions(mel, axis: 0)
        return mel.asType(.float32)
    }
}

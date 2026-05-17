import Foundation

/// Gemma 4 native ASR is intentionally disabled in this build path.
///
/// Newer mlx-swift-lm releases removed APIs used by the previous implementation.
/// We keep this bridge as a stable surface but return a clear runtime error.
enum FlmGemma4ASRBridge {
    static func transcribe(
        modelPath _: String,
        audioURL _: URL,
        language _: String?,
        maxTokens _: Int
    ) async throws -> String {
        throw NSError(
            domain: "FlmGemma4ASR",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Gemma 4 native speech-to-text is disabled in this build. "
                        + "Use Qwen3-ASR or another mlx_audio ASR checkpoint."
            ]
        )
    }
}

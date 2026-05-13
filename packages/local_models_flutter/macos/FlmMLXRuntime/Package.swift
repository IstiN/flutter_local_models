// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FlmMLXRuntime",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "FlmMLXRuntime", targets: ["FlmMLXRuntime"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // Patched locally: base Qwen3-TTS routes preset `--voice` as `speaker` (matches Python).
        .package(path: "../../../mlx-audio-swift"),
    ],
    targets: [
        .target(
            name: "FlmMLXRuntime",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            ]
        ),
    ]
)

// swift-tools-version: 5.10
import PackageDescription

// Minimal speech-swift subset. Source pin and notices: PROVENANCE.md.
let package = Package(
    name: "SpeechSwiftTTS",
    platforms: [.iOS("18.0"), .macOS("15.0")],
    products: [
        .library(name: "Qwen3TTS", targets: ["Qwen3TTS"]),
        .library(name: "MossTTSNano", targets: ["MossTTSNano"]),
        .library(name: "SpeechAudioCommon", targets: ["AudioCommon"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", revision: "ab924c82ead3b970caaa1c0ac11171de23f0305a"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.0")
    ],
    targets: [
        .target(name: "AudioCommon", dependencies: [.product(name: "Hub", package: "swift-transformers")]),
        .target(name: "MLXCommon", dependencies: ["AudioCommon",
            .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXFast", package: "mlx-swift"), .product(name: "MLXFFT", package: "mlx-swift")]),
        .target(name: "Qwen3TTS", dependencies: ["AudioCommon", "MLXCommon",
            .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXFast", package: "mlx-swift")]),
        .target(name: "MossTTSNano", dependencies: ["AudioCommon"])
    ]
)

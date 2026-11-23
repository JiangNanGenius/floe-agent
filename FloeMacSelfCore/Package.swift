// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
//
// Floe Mac self-owned runtime composition foundation.
//
// This package does NOT implement a second agent harness, a second permission
// policy or a second persistence model. The Floe* targets below are directory
// symlinks to the exact upstream FloeAgent sources (see MANIFEST.json); SwiftPM
// compiles those bytes into the real FloeCore/FloeModels/FloeProviders/
// FloeTools/FloeSecurity/FloePersistence/FloeAgentRuntime modules. A drift in
// any upstream byte is therefore a build change, never a silent fork.
//
// The only new module is FloeMacSelfCore: a bounded macOS composition layer
// that opens a host-owned SQLite database, prepares a run through the existing
// SQLiteRunLaunchStore, starts the existing ConversationRunService via
// startPrepared(goal:userMessageID:), and exposes real events, approval
// resolution, cancellation and lifecycle. It does not own the UI process.
import PackageDescription

let upstreamSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "FloeMacSelfCore",
    platforms: [.macOS(.v15)],
    products: [
        // One product vends the composition layer plus the exact upstream
        // modules it was compiled against, so the host never links a second
        // copy of a module under the same name. If the host also links the
        // standalone FloeAgent package products, choose one source per module.
        .library(
            name: "FloeMacSelfCore",
            targets: [
                "FloeMacSelfCore",
                "FloeAgentRuntime",
                "FloePersistence",
                "FloeSecurity",
                "FloeTools",
                "FloeProviders",
                "FloeSkills",
                "FloeModels",
                "FloeCore",
                "FloeSync",
                "FloeSyncCore",
                "FloeMarkdown",
                "FloeLocalModelCatalog",
                "FloeLocalModels",
            ]
        )
    ],
    dependencies: [
        .package(path: "../FloeDesktopSync"),
        .package(path: "../FloeAgent/ThirdParty/swift-crypto"),
        .package(name: "mlx-swift-lm", path: "../FloeAgent/ThirdParty/MLXSwiftLM"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git",
                 revision: "ab924c82ead3b970caaa1c0ac11171de23f0305a"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.8.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        // Matches the main FloeAgent host lock; swift-crypto pulls this
        // transitively and the exact pin prevents a second incompatible copy.
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.1"),
    ],
    targets: [
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/JiangNanGenius/floe-agent/releases/download/llama-runtime-b10581-floe1/llama-b10581-floe1-xcframework.zip",
            checksum: "95e359c6a93b3bc791c5671970ca37f7bdbc9bfae62b55551750186380cea284"
        ),
        .target(name: "FloeLlamaVisionShim", publicHeadersPath: "include"),
        .target(
            name: "FloeSkills",
            dependencies: ["FloeTools", .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                           .product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: upstreamSwiftSettings
        ),
        .target(name: "FloeMarkdown", dependencies: ["FloeCore"]),
        .target(
            name: "FloeLocalModelCatalog",
            dependencies: ["FloeCore"],
            swiftSettings: upstreamSwiftSettings
        ),
        .target(
            name: "FloeLocalModels",
            dependencies: [
                "FloeCore", "FloeModels", "FloeProviders", "FloeLocalModelCatalog", "LlamaFramework", "FloeLlamaVisionShim",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(name: "FloeSyncCore", dependencies: ["FloeCore"], swiftSettings: upstreamSwiftSettings),
        .target(
            name: "FloeSync",
            dependencies: ["FloeCore", "FloeModels", "FloeSyncCore", "FloePersistence", "FloeSecurity"],
            swiftSettings: upstreamSwiftSettings
        ),
        // Narrow C primitives used by FloeCore. Exact upstream bytes.
        .target(
            name: "CFloeExtentShim",
            path: "Sources/CFloeExtentShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CFloeSparseRewriteShim",
            path: "Sources/CFloeSparseRewriteShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "FloeCore",
            dependencies: [
                "CFloeExtentShim",
                "CFloeSparseRewriteShim",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/FloeCore",
            swiftSettings: upstreamSwiftSettings
        ),
        .target(
            name: "FloeModels",
            dependencies: [
                "FloeCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/FloeModels",
            swiftSettings: upstreamSwiftSettings
        ),
        .target(
            name: "FloeProviders",
            dependencies: ["FloeCore", "FloeModels"],
            path: "Sources/FloeProviders",
            swiftSettings: upstreamSwiftSettings
        ),
        .target(
            name: "FloeTools",
            dependencies: [
                "FloeCore",
                "FloeModels",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/FloeTools",
            swiftSettings: upstreamSwiftSettings
        ),
        .target(
            name: "FloeSecurity",
            dependencies: [
                "FloeCore",
                "FloeModels",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/FloeSecurity",
            resources: [.process("Resources")],
            swiftSettings: upstreamSwiftSettings
        ),
        .target(
            name: "FloePersistence",
            dependencies: [
                "FloeCore",
                "FloeModels",
                "FloeSecurity",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/FloePersistence",
            swiftSettings: upstreamSwiftSettings
        ),
        .target(
            name: "FloeAgentRuntime",
            dependencies: [
                "FloeCore",
                "FloeModels",
                "FloeProviders",
                "FloeTools",
                "FloePersistence",
                "FloeSecurity",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/FloeAgentRuntime",
            swiftSettings: upstreamSwiftSettings
        ),

        // The new composition layer. No source outside FloeMacSelfCore/ is
        // edited; the upstream targets above are read-only symlinks.
        .target(
            name: "FloeMacSelfCore",
            dependencies: [
                "FloeCore",
                "FloeModels",
                "FloeProviders",
                "FloeSkills",
                "FloeTools",
                "FloeSecurity",
                "FloePersistence",
                "FloeAgentRuntime",
                .product(name: "FloeDesktopSync", package: "FloeDesktopSync"),
                // The self-core admission/authority tables use the same
                // serialized GRDB writer/reader as the upstream stores. This
                // adds no second database or schema owner.
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/FloeMacSelfCore",
            swiftSettings: upstreamSwiftSettings
        ),
        .target(
            name: "FloeTestSupport",
            dependencies: ["FloeCore", "FloeModels"],
            path: "Tests/FloeTestSupport",
            swiftSettings: upstreamSwiftSettings
        ),
        .testTarget(
            name: "FloeAgentRuntimeTests",
            dependencies: ["FloeAgentRuntime", "FloePersistence", "FloeTestSupport"],
            path: "Tests/FloeAgentRuntimeTests",
            swiftSettings: upstreamSwiftSettings
        ),
        .testTarget(
            name: "FloeMacSelfCoreTests",
            dependencies: [
                "FloeMacSelfCore",
                "FloeCore",
                "FloeModels",
                "FloeProviders",
                "FloeTools",
                "FloeSecurity",
                "FloePersistence",
                "FloeAgentRuntime",
                .product(name: "FloeDesktopSync", package: "FloeDesktopSync"),
                // Direct use of DatabaseManager.writer closures and
                // installSchema(in: Database) in test setup.
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/FloeMacSelfCoreTests",
            swiftSettings: upstreamSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

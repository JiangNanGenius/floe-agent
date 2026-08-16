// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeAgent",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "FloeCore", targets: ["FloeCore"]),
        .library(name: "FloeModels", targets: ["FloeModels"]),
        .library(name: "FloeProviders", targets: ["FloeProviders"]),
        .library(name: "FloeAgentRuntime", targets: ["FloeAgentRuntime"]),
        .library(name: "FloeTools", targets: ["FloeTools"]),
        .library(name: "FloeSkills", targets: ["FloeSkills"]),
        .library(name: "FloePersistence", targets: ["FloePersistence"]),
        .library(name: "FloeSecurity", targets: ["FloeSecurity"]),
        .library(name: "FloeSyncCore", targets: ["FloeSyncCore"]),
        .library(name: "FloeSync", targets: ["FloeSync"]),
        .library(name: "FloeDocuments", targets: ["FloeDocuments"]),
        .library(name: "FloeImages", targets: ["FloeImages"]),
        .library(name: "FloeSSH", targets: ["FloeSSH"]),
        .library(name: "FloeVNC", targets: ["FloeVNC"]),
        .library(name: "FloeMarkdown", targets: ["FloeMarkdown"]),
        .library(name: "FloeWorkspace", targets: ["FloeWorkspace"]),
        .library(name: "FloeExecution", targets: ["FloeExecution"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.8.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.88.0"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", exact: "0.3.6"),
        // NOTE: dev plan pinned apple/swift-nio-ssh 0.11.0 (does not exist).
        // Citadel uses the API-compatible Wellz26 fork 0.3.x. FloeSSH imports
        // NIOSSH directly for strict host-key validation, so this direct pin
        // intentionally matches Citadel's transitive package identity.
        // NOTE: dev plan pinned Citadel 0.11.0 (does not exist). Latest tag
        // 0.9.2 requires swift-crypto <2.1 (conflicts with our 4.1.0 pin);
        // main branch (this revision) supports swift-crypto 3.12.3+.
        // Revision pin keeps the build reproducible. Deviation flagged.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", revision: "ae8562f895de06ccb86fdb1cbb65fd99c8976e12"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.10.0"),
        // NOTE: dev plan pinned swift-crypto 4.1.0, but Citadel (main) caps
        // at <4.0.0. 3.15.1 is the newest 3.x. Deviation flagged.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        // NOTE: dev plan pinned "3.0.0" which does not exist; the highest
        // tag (1.1.0) transitively depends on an unstable CryptoSwift pin,
        // so a stable-version requirement cannot resolve. Revision pin of
        // the 1.1.0 tag commit (deviation flagged in report).
        .package(url: "https://github.com/royalapplications/royalvnc.git", revision: "92d4427c73817d8f849bb289ff190aa4b40c44ea")
    ],
    targets: [
        // MARK: - Cross-platform targets (buildable on macOS host without iOS SDK)

        .target(
            name: "FloeCore",
            dependencies: [],
            path: "Sources/FloeCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeModels",
            dependencies: [
                "FloeCore",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeModels",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeProviders",
            dependencies: ["FloeCore", "FloeModels"],
            path: "Sources/FloeProviders",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeAgentRuntime",
            dependencies: [
                "FloeCore", "FloeModels", "FloeProviders", "FloeTools",
                "FloePersistence", "FloeSecurity",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeAgentRuntime",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeTools",
            dependencies: ["FloeCore", "FloeModels"],
            path: "Sources/FloeTools",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeSkills",
            dependencies: [
                "FloeTools",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeSkills",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeExecution",
            dependencies: ["FloeCore", "FloeTools", "FloeSSH"],
            path: "Sources/FloeExecution",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloePersistence",
            dependencies: [
                "FloeCore",
                "FloeModels",
                "FloeSecurity",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/FloePersistence",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeSecurity",
            dependencies: [
                "FloeCore",
                "FloeModels",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeSecurity",
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeSyncCore",
            dependencies: ["FloeCore"],
            path: "Sources/FloeSyncCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        // MARK: - iOS-only targets (require full Xcode, not buildable on this host)

        .target(
            name: "FloeSync",
            dependencies: ["FloeCore", "FloeSyncCore", "FloePersistence", "FloeSecurity"],
            path: "Sources/FloeSync",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeDocuments",
            dependencies: ["FloeCore", "FloeTools"],
            path: "Sources/FloeDocuments",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeImages",
            dependencies: ["FloeCore", "FloeTools"],
            path: "Sources/FloeImages",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeSSH",
            dependencies: [
                "FloeCore",
                "FloeSecurity",
                "FloePersistence",
                "FloeTools",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeSSH",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeVNC",
            dependencies: [
                "FloeCore",
                "FloePersistence",
                .product(name: "RoyalVNCKit", package: "royalvnc")
            ],
            path: "Sources/FloeVNC",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeMarkdown",
            dependencies: ["FloeCore"],
            path: "Sources/FloeMarkdown",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeWorkspace",
            dependencies: [
                "FloeCore",
                "FloeModels",
                "FloeTools",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeWorkspace",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        // MARK: - Test targets

        .target(
            name: "FloeTestSupport",
            dependencies: ["FloeCore", "FloeModels"],
            path: "Tests/FloeTestSupport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeCoreTests",
            dependencies: ["FloeCore", "FloeTestSupport"],
            path: "Tests/FloeCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeModelsTests",
            dependencies: ["FloeModels", "FloeTestSupport"],
            path: "Tests/FloeModelsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeProvidersTests",
            dependencies: ["FloeProviders", "FloeTestSupport"],
            path: "Tests/FloeProvidersTests",
            resources: [.process("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeAgentRuntimeTests",
            dependencies: ["FloeAgentRuntime", "FloePersistence", "FloeTestSupport"],
            path: "Tests/FloeAgentRuntimeTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeToolsTests",
            dependencies: ["FloeTools", "FloeAgentRuntime", "FloeTestSupport"],
            path: "Tests/FloeToolsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeSkillsTests",
            dependencies: ["FloeSkills", "FloeTools"],
            path: "Tests/FloeSkillsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloePersistenceTests",
            dependencies: ["FloePersistence", "FloeTestSupport"],
            path: "Tests/FloePersistenceTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "FloeSyncTests",
            dependencies: ["FloeSync", "FloePersistence"],
            path: "Tests/FloeSyncTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures")
            ]
        ),

        .testTarget(
            name: "FloeSecurityTests",
            dependencies: ["FloeSecurity", "FloeTestSupport"],
            path: "Tests/FloeSecurityTests",
            resources: [.process("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeDocumentsTests",
            dependencies: ["FloeDocuments"],
            path: "Tests/FloeDocumentsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeSSHTests",
            dependencies: ["FloeSSH"],
            path: "Tests/FloeSSHTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeMarkdownTests",
            dependencies: ["FloeMarkdown"],
            path: "Tests/FloeMarkdownTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeImagesTests",
            dependencies: ["FloeImages"],
            path: "Tests/FloeImagesTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeWorkspaceTests",
            dependencies: ["FloeWorkspace", "FloeTools", "FloeModels", "FloeTestSupport"],
            path: "Tests/FloeWorkspaceTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeExecutionTests",
            dependencies: [
                "FloeExecution", "FloeCore", "FloeTools", "FloeModels",
                "FloeAgentRuntime", "FloeSSH", "FloePersistence", "FloeTestSupport"
            ],
            path: "Tests/FloeExecutionTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)

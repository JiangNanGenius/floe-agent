// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Unified create-from-zero starter SDK for the exact 20 agreed engines.
// This package is independent of the App target, hosts and release tooling.
// It reuses the existing component packages/templates rather than defining a
// second engine/import/runtime architecture.
let package = Package(
    name: "FloeGameStarterKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameStarterKit", targets: ["FloeGameStarterKit"]),
        .executable(name: "floe-game-starter", targets: ["GameStarterCLI"]),
    ],
    dependencies: [
        .package(name: "FloeGameKit", path: "../FloeGameKit"),
        .package(name: "FloeGameTouchKit", path: "../FloeGameTouchKit"),
        .package(name: "FloeGameAuthoringKit", path: "../FloeGameAuthoringKit"),
        .package(name: "FloeRPGProjectKit", path: "../FloeRPGProjectKit"),
        .package(name: "FloeGameNarrativeKit", path: "../FloeGameNarrativeKit"),
        .package(name: "FloeGamePortableKit", path: "../FloeGamePortableKit"),
        .package(name: "FloeGameGDevelopKit", path: "../FloeGameGDevelopKit"),
    ],
    targets: [
        .target(
            name: "FloeGameStarterKit",
            dependencies: [
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameTouch", package: "FloeGameTouchKit"),
                .product(name: "FloeGameAuthoring", package: "FloeGameAuthoringKit"),
                .product(name: "FloeRPGCore", package: "FloeRPGProjectKit"),
                .product(name: "FloeGameNarrativeKit", package: "FloeGameNarrativeKit"),
                .product(name: "FloeGamePortableKit", package: "FloeGamePortableKit"),
                .product(name: "FloeGameGDevelopKit", package: "FloeGameGDevelopKit"),
            ],
            resources: [
                .copy("Resources/Catalog"),
                .copy("Resources/Templates"),
                .copy("Resources/Licenses"),
            ]
        ),
        .executableTarget(
            name: "GameStarterCLI",
            dependencies: [
                "FloeGameStarterKit",
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameAuthoring", package: "FloeGameAuthoringKit"),
            ]
        ),
        .testTarget(
            name: "FloeGameStarterKitTests",
            dependencies: [
                "FloeGameStarterKit",
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameTouch", package: "FloeGameTouchKit"),
                .product(name: "FloeGameAuthoring", package: "FloeGameAuthoringKit"),
                .product(name: "FloeRPGCore", package: "FloeRPGProjectKit"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)

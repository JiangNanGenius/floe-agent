// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Source-only execution bridge for the predeveloped game SDK. It deliberately
// contains no Main/App target: the concrete Main binding lives in
// `MainBinding/` and is compiled later in the serialized native window.
let package = Package(
    name: "FloeGameExecutionBridge",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameExecutionBridge", targets: ["FloeGameExecutionBridge"])
    ],
    dependencies: [
        .package(name: "FloeGameKit", path: "../FloeGameKit"),
        .package(name: "FloeGameBuildKit", path: "../FloeGameBuildKit"),
        .package(name: "FloeGameRunKit", path: "../FloeGameRunKit"),
        .package(name: "FloeGamePortableKit", path: "../FloeGamePortableKit"),
        .package(name: "FloeGameNarrativeKit", path: "../FloeGameNarrativeKit"),
        .package(name: "FloeGameGDevelopKit", path: "../FloeGameGDevelopKit")
    ],
    targets: [
        .target(
            name: "FloeGameExecutionBridge",
            dependencies: [
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameBuildKit", package: "FloeGameBuildKit"),
                .product(name: "FloeGameRunKit", package: "FloeGameRunKit"),
                .product(name: "FloeGamePortableKit", package: "FloeGamePortableKit"),
                .product(name: "FloeGameNarrativeKit", package: "FloeGameNarrativeKit"),
                .product(name: "FloeGameGDevelopKit", package: "FloeGameGDevelopKit")
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "FloeGameExecutionBridgeTests",
            dependencies: [
                "FloeGameExecutionBridge",
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameBuildKit", package: "FloeGameBuildKit"),
                .product(name: "FloeGameRunKit", package: "FloeGameRunKit"),
                .product(name: "FloeGamePortableKit", package: "FloeGamePortableKit")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Isolated source package for the 20-engine project selection/lifecycle flow.
// It composes the frozen predevelopment SDK instead of copying or replacing it.
let package = Package(
    name: "FloeGameProjectFlow",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameProjectFlow", targets: ["FloeGameProjectFlow"]),
        .library(name: "FloeGameProjectSelectionUI", targets: ["FloeGameProjectSelectionUI"])
    ],
    dependencies: [
        .package(name: "FloeGameKit", path: "../FloeGameKit"),
        .package(name: "FloeGameStarterKit", path: "../FloeGameStarterKit"),
        .package(name: "FloeGameAuthoringKit", path: "../FloeGameAuthoringKit"),
        .package(name: "FloeGameRunKit", path: "../FloeGameRunKit"),
        .package(name: "FloeGameIDEBridge", path: "../FloeGameIDEBridge")
    ],
    targets: [
        .target(
            name: "FloeGameProjectFlow",
            dependencies: [
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameWebKit", package: "FloeGameKit"),
                .product(name: "FloeGameStarterKit", package: "FloeGameStarterKit"),
                .product(name: "FloeGameAuthoring", package: "FloeGameAuthoringKit"),
                .product(name: "FloeGameRunKit", package: "FloeGameRunKit"),
                .product(name: "FloeGameIDEBridge", package: "FloeGameIDEBridge")
            ]
        ),
        .target(
            name: "FloeGameProjectSelectionUI",
            dependencies: [
                "FloeGameProjectFlow",
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameStarterKit", package: "FloeGameStarterKit")
            ]
        ),
        .testTarget(
            name: "FloeGameProjectFlowTests",
            dependencies: [
                "FloeGameProjectFlow",
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameWebKit", package: "FloeGameKit"),
                .product(name: "FloeGameStarterKit", package: "FloeGameStarterKit"),
                .product(name: "FloeGameAuthoring", package: "FloeGameAuthoringKit"),
                .product(name: "FloeGameRunKit", package: "FloeGameRunKit"),
                .product(name: "FloeGameIDEBridge", package: "FloeGameIDEBridge")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)

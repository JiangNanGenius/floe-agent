// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Development-only control plane for game authoring. It is a sibling of the
// other Floe game packages; it never owns project files, Git, environments or
// a second engine runtime. The App decides when a development bridge is
// attached and only compiled hosts may expose it.
let package = Package(
    name: "FloeGameDeveloperKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameDeveloperCore", targets: ["FloeGameDeveloperCore"]),
        .library(name: "FloeGameDeveloperWebKit", targets: ["FloeGameDeveloperWebKit"]),
        .library(name: "FloeGameDeveloperUI", targets: ["FloeGameDeveloperUI"]),
        .executable(name: "floe-game-developer-matrix", targets: ["GameDeveloperMatrixCLI"]),
    ],
    dependencies: [
        .package(name: "FloeGameKit", path: "../FloeGameKit"),
    ],
    targets: [
        .target(
            name: "FloeGameDeveloperCore",
            dependencies: [
                .product(name: "FloeGameCore", package: "FloeGameKit"),
            ],
            resources: [.copy("Resources")]
        ),
        .target(
            name: "FloeGameDeveloperWebKit",
            dependencies: [
                "FloeGameDeveloperCore",
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameWebKit", package: "FloeGameKit"),
            ]
        ),
        .target(
            name: "FloeGameDeveloperUI",
            dependencies: [
                "FloeGameDeveloperCore",
            ]
        ),
        .executableTarget(
            name: "GameDeveloperMatrixCLI",
            dependencies: ["FloeGameDeveloperCore"]
        ),
        .testTarget(
            name: "FloeGameDeveloperKitTests",
            dependencies: [
                "FloeGameDeveloperCore",
                "FloeGameDeveloperUI",
                .product(name: "FloeGameCore", package: "FloeGameKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

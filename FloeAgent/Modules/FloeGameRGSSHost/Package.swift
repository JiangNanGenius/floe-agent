// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Concrete host integration for the three legacy RPG Maker engines
// (XP/RGSS1, VX/RGSS2, VX Ace/RGSS3). The package contains no engine binary,
// no RTP and no game content. It composes the frozen SDK's typed RGSS guest
// runtime with the App's existing resolved Linux environment, display, input,
// file and save services.
//
// The Linux target is a separate compile boundary so the Core product can be
// built without the App module graph. Main integration is intentionally a
// narrow set of patches under MainBinding/ + AppIntegration/.
let package = Package(
    name: "FloeGameRGSSHost",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameRGSSHostCore", targets: ["FloeGameRGSSHostCore"]),
        .library(name: "FloeGameRGSSHostLinux", targets: ["FloeGameRGSSHostLinux"]),
    ],
    dependencies: [
        .package(path: "../FloeGameKit"),
        .package(path: "../FloeGameRGSSKit"),
        .package(path: "../FloeGameRunKit"),
        .package(path: "../FloeGameIDEBridge"),
        .package(path: "../FloeGameDeveloperKit"),
        .package(path: "../FloeGameTouchKit"),
        .package(path: "../FloeRPGProjectKit"),
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "FloeGameRGSSHostCore",
            dependencies: [
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameWebKit", package: "FloeGameKit"),
                .product(name: "FloeGameRGSS", package: "FloeGameRGSSKit"),
                .product(name: "FloeGameRunKit", package: "FloeGameRunKit"),
                .product(name: "FloeGameIDEBridge", package: "FloeGameIDEBridge"),
                .product(name: "FloeGameDeveloperCore", package: "FloeGameDeveloperKit"),
                .product(name: "FloeGameTouch", package: "FloeGameTouchKit"),
                .product(name: "FloeRPGCore", package: "FloeRPGProjectKit"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .target(
            name: "FloeGameRGSSHostLinux",
            dependencies: [
                "FloeGameRGSSHostCore",
                .product(name: "FloeCore", package: "FloeAgent"),
                .product(name: "FloeExecution", package: "FloeAgent"),
                .product(name: "FloeTools", package: "FloeAgent"),
                .product(name: "FloeVNC", package: "FloeAgent"),
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameWebKit", package: "FloeGameKit"),
                .product(name: "FloeGameRGSS", package: "FloeGameRGSSKit"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "FloeGameRGSSHostCoreTests",
            dependencies: [
                "FloeGameRGSSHostCore",
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameRGSS", package: "FloeGameRGSSKit"),
                .product(name: "FloeGameRunKit", package: "FloeGameRunKit"),
                .product(name: "FloeGameTouch", package: "FloeGameTouchKit"),
                .product(name: "FloeGameWebKit", package: "FloeGameKit"),
                .product(name: "FloeRPGCore", package: "FloeRPGProjectKit"),
            ]
        ),
        .testTarget(
            name: "FloeGameRGSSHostLinuxTests",
            dependencies: [
                "FloeGameRGSSHostLinux",
                "FloeGameRGSSHostCore",
                .product(name: "FloeCore", package: "FloeAgent"),
                .product(name: "FloeExecution", package: "FloeAgent"),
                .product(name: "FloeTools", package: "FloeAgent"),
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameRGSS", package: "FloeGameRGSSKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

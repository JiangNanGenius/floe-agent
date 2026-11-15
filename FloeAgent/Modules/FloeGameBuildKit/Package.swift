// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Use the same archive dependency and revision as the App and document editors.
let package = Package(
    name: "FloeGameBuildKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameBuildKit", targets: ["FloeGameBuildKit"]),
        .executable(name: "floe-game-build-export", targets: ["GameBuildExport"])
    ],
    dependencies: [
        .package(name: "FloeGameKit", path: "../FloeGameKit"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .executableTarget(
            name: "GameBuildExport",
            dependencies: ["FloeGameBuildKit"]
        ),
        .target(
            name: "FloeGameBuildKit",
            dependencies: [
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "FloeGameBuildKitTests",
            dependencies: ["FloeGameBuildKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)

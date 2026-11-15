// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Independent predevelopment package. App integration is deliberately separate.
let package = Package(
    name: "FloeGameKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameCore", targets: ["FloeGameCore"]),
        .library(name: "FloeGameWebKit", targets: ["FloeGameWebKit"]),
        .executable(name: "floe-game-preflight", targets: ["GamePreflight"]),
        .executable(name: "floe-game-runtime-qualification", targets: ["GameRuntimeQualification"])
    ],
    targets: [
        .target(name: "FloeGameCore"),
        .target(name: "FloeGameWebKit", dependencies: ["FloeGameCore"], resources: [.copy("Resources/Developer")]),
        .executableTarget(name: "GamePreflight", dependencies: ["FloeGameCore"]),
        .executableTarget(name: "GameRuntimeQualification", dependencies: ["FloeGameCore", "FloeGameWebKit"]),
        .testTarget(name: "FloeGameCoreTests", dependencies: ["FloeGameCore"]),
        .testTarget(name: "FloeGameWebKitTests", dependencies: ["FloeGameCore", "FloeGameWebKit"])
    ],
    swiftLanguageModes: [.v6]
)

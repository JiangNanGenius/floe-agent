// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

let package = Package(name: "FloeGameRuntimeKit", platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeGameRuntime", targets: ["FloeGameRuntime"]),
               .executable(name: "floe-game-multi-runtime", targets: ["GameMultiRuntimeQualification"])],
    dependencies: [.package(path: "../FloeGameKit"), .package(path: "../FloeGameNarrativeKit")],
    targets: [
        .target(name: "FloeGameRuntime", dependencies: [.product(name: "FloeGameCore", package: "FloeGameKit")], resources: [.copy("Resources")]),
        .executableTarget(name: "GameMultiRuntimeQualification", dependencies: ["FloeGameRuntime", .product(name: "FloeGameCore", package: "FloeGameKit"), .product(name: "FloeGameWebKit", package: "FloeGameKit"), .product(name: "FloeGameNarrativeKit", package: "FloeGameNarrativeKit")]),
        .testTarget(name: "FloeGameRuntimeTests", dependencies: ["FloeGameRuntime"])
    ], swiftLanguageModes: [.v6])

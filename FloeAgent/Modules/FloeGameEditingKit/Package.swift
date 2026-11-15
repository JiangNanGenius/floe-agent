// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Independent predevelopment package: native auxiliary game editors.
// App integration is deliberately separate (coordinator-owned).
let package = Package(
    name: "FloeGameEditingKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameEditingCore", targets: ["FloeGameEditingCore"]),
        .library(name: "FloeGameEditingUI", targets: ["FloeGameEditingUI"]),
        .executable(name: "floe-game-editing-sample", targets: ["GameEditingSample"])
    ],
    dependencies: [
        .package(path: "../FloeGameKit")
    ],
    targets: [
        .target(name: "FloeGameEditingCore", dependencies: [
            .product(name: "FloeGameCore", package: "FloeGameKit")
        ]),
        .target(name: "FloeGameEditingUI", dependencies: ["FloeGameEditingCore", .product(name: "FloeGameCore", package: "FloeGameKit")]),
        .executableTarget(name: "GameEditingSample", dependencies: ["FloeGameEditingCore", "FloeGameEditingUI"]),
        .testTarget(name: "FloeGameEditingTests", dependencies: ["FloeGameEditingCore"])
    ],
    swiftLanguageModes: [.v6]
)

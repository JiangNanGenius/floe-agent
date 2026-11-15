// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Independent predevelopment package: native PNG pixel, sprite-sheet and
// animation editing for the auxiliary game editors. App/host integration is
// coordinator-owned. No third-party engine or image dependency is used.
let package = Package(
    name: "FloeGameSpriteKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameSpriteCore", targets: ["FloeGameSpriteCore"]),
        .library(name: "FloeGameSpriteUI", targets: ["FloeGameSpriteUI"])
    ],
    dependencies: [
        .package(path: "../FloeGameKit"),
        .package(path: "../FloeGameEditingKit")
    ],
    targets: [
        .target(name: "FloeGameSpriteCore", dependencies: [
            .product(name: "FloeGameCore", package: "FloeGameKit"),
            .product(name: "FloeGameEditingCore", package: "FloeGameEditingKit")
        ]),
        .target(name: "FloeGameSpriteUI", dependencies: [
            "FloeGameSpriteCore",
            .product(name: "FloeGameCore", package: "FloeGameKit"),
            .product(name: "FloeGameEditingCore", package: "FloeGameEditingKit"),
            .product(name: "FloeGameEditingUI", package: "FloeGameEditingKit")
        ]),
        .testTarget(name: "FloeGameSpriteKitTests", dependencies: [
            "FloeGameSpriteCore",
            "FloeGameSpriteUI",
            .product(name: "FloeGameCore", package: "FloeGameKit"),
            .product(name: "FloeGameEditingCore", package: "FloeGameEditingKit")
        ])
    ],
    swiftLanguageModes: [.v6]
)

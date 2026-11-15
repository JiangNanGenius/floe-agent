// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// The package uses the same game project and editing session as the App.
let package = Package(
    name: "FloeRPGTilesetKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeRPGTilesetKit", targets: ["FloeRPGTilesetKit"]),
        .library(name: "FloeRPGTilesetUI", targets: ["FloeRPGTilesetUI"]),
        .executable(name: "floe-rpg-tileset-render", targets: ["RPGTilesetRenderProbe"])
    ],
    dependencies: [
        .package(path: "../FloeGameKit"),
        .package(path: "../FloeGameEditingKit"),
        .package(path: "../FloeRPGProjectKit")
    ],
    targets: [
        .target(name: "FloeRPGTilesetKit", dependencies: [
            .product(name: "FloeGameCore", package: "FloeGameKit"),
            .product(name: "FloeGameEditingCore", package: "FloeGameEditingKit"),
            .product(name: "FloeRPGCore", package: "FloeRPGProjectKit")
        ], resources: [.process("Resources")]),
        .target(name: "FloeRPGTilesetUI", dependencies: [
            "FloeRPGTilesetKit",
            .product(name: "FloeGameCore", package: "FloeGameKit"),
            .product(name: "FloeGameEditingCore", package: "FloeGameEditingKit"),
            .product(name: "FloeGameEditingUI", package: "FloeGameEditingKit"),
            .product(name: "FloeRPGCore", package: "FloeRPGProjectKit")
        ]),
        .executableTarget(name: "RPGTilesetRenderProbe", dependencies: [
            "FloeRPGTilesetKit",
            .product(name: "FloeGameCore", package: "FloeGameKit"),
            .product(name: "FloeRPGCore", package: "FloeRPGProjectKit")
        ]),
        .testTarget(name: "FloeRPGTilesetKitTests", dependencies: [
            "FloeRPGTilesetKit", "FloeRPGTilesetUI",
            .product(name: "FloeRPGCore", package: "FloeRPGProjectKit"),
            .product(name: "FloeGameEditingCore", package: "FloeGameEditingKit"),
            .product(name: "FloeGameCore", package: "FloeGameKit")
        ], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)

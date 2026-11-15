// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Independent predevelopment package: RPG Maker XP/VX/VX Ace runtime adapters.
// App/UI integration is coordinator-owned and deliberately separate. The
// separately distributed mkxp-web Web resource is not compiled into the App.
let package = Package(
    name: "FloeGameRGSSKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameRGSS", targets: ["FloeGameRGSS"]),
        .library(name: "FloeGameRGSSWebKit", targets: ["FloeGameRGSSWebKit"])
    ],
    dependencies: [
        .package(path: "../FloeGameKit"),
        .package(path: "../FloeGameTouchKit")
    ],
    targets: [
        .target(name: "FloeGameRGSS", dependencies: [
            .product(name: "FloeGameCore", package: "FloeGameKit")
        ], resources: [.copy("Resources")]),
        .target(name: "FloeGameRGSSWebKit", dependencies: [
            "FloeGameRGSS",
            .product(name: "FloeGameCore", package: "FloeGameKit"),
            .product(name: "FloeGameWebKit", package: "FloeGameKit")
        ]),
        .testTarget(name: "FloeGameRGSSKitTests", dependencies: ["FloeGameRGSS", "FloeGameRGSSWebKit",
            .product(name: "FloeGameTouch", package: "FloeGameTouchKit")], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)

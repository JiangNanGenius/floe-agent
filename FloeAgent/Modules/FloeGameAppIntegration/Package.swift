// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// App-integration support library for the Floe game workflow. This package is
// deliberately small and App-independent so the coordinator can compile and
// test it before the serialized native window. It contains no Main source and
// no second IDE, Git layer, file tree or engine runtime.
let package = Package(
    name: "FloeGameAppIntegration",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameAppIntegration", targets: ["FloeGameAppIntegration"])
    ],
    dependencies: [
        .package(name: "FloeGameKit", path: "../FloeGameKit"),
        .package(name: "FloeGameStarterKit", path: "../FloeGameStarterKit")
    ],
    targets: [
        .target(name: "FloeGameAppIntegration", dependencies: [
            .product(name: "FloeGameCore", package: "FloeGameKit"),
            .product(name: "FloeGameStarterKit", package: "FloeGameStarterKit")
        ]),
        .testTarget(name: "FloeGameAppIntegrationTests", dependencies: [
            "FloeGameAppIntegration",
            .product(name: "FloeGameCore", package: "FloeGameKit"),
            .product(name: "FloeGameStarterKit", package: "FloeGameStarterKit")
        ])
    ],
    swiftLanguageModes: [.v6]
)

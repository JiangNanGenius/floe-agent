// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

let package = Package(name: "FloeGamePlayIntegration", platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeGamePlayIntegration", targets: ["FloeGamePlayIntegration"])],
    dependencies: [.package(path: "../FloeGameTouchKit")],
    targets: [
        .target(name: "FloeGamePlayIntegration", dependencies: [
            .product(name: "FloeGameTouch", package: "FloeGameTouchKit")]),
        .testTarget(name: "FloeGamePlayIntegrationTests", dependencies: ["FloeGamePlayIntegration"])
    ], swiftLanguageModes: [.v6])

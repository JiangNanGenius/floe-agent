// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

let package = Package(name: "FloeGameIDEBridge", platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeGameIDEBridge", targets: ["FloeGameIDEBridge"])],
    dependencies: [.package(path: "../FloeGameKit")],
    targets: [
        .target(name: "FloeGameIDEBridge", dependencies: [.product(name: "FloeGameCore", package: "FloeGameKit")]),
        .testTarget(name: "FloeGameIDEBridgeTests", dependencies: ["FloeGameIDEBridge"])
    ], swiftLanguageModes: [.v6])

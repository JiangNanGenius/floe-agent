// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

let package = Package(name: "FloeGameProjectIntegration",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeGameProjectIntegration", targets: ["FloeGameProjectIntegration"])],
    dependencies: [.package(path: "../FloeGameKit"),
                   .package(path: "../FloeGameAuthoringKit")],
    targets: [
        .target(name: "FloeGameProjectIntegration", dependencies: [
            .product(name: "FloeGameCore", package: "FloeGameKit"),
            .product(name: "FloeGameAuthoring", package: "FloeGameAuthoringKit")]),
        .testTarget(name: "FloeGameProjectIntegrationTests", dependencies: ["FloeGameProjectIntegration"])
    ], swiftLanguageModes: [.v6])

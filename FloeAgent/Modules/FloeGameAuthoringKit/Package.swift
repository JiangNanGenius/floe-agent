// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription
let package = Package(name: "FloeGameAuthoringKit", platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeGameAuthoring", targets: ["FloeGameAuthoring"]),
               .library(name: "FloeGameAuthoringUI", targets: ["FloeGameAuthoringUI"])],
    dependencies: [.package(path: "../FloeGameKit")],
    targets: [
        .target(name: "FloeGameAuthoring", dependencies: [.product(name: "FloeGameCore", package: "FloeGameKit")]),
        .target(name: "FloeGameAuthoringUI", dependencies: ["FloeGameAuthoring"]),
        .testTarget(name: "FloeGameAuthoringTests", dependencies: ["FloeGameAuthoring"])
    ], swiftLanguageModes: [.v6])

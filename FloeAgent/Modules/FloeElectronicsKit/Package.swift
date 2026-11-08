// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

let package = Package(
    name: "FloeElectronicsKit",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [
        .library(name: "FloeElectronicsCore", targets: ["FloeElectronicsCore"]),
        .library(name: "FloeElectronicsUI", targets: ["FloeElectronicsUI"])
    ],
    targets: [
        .target(name: "FloeElectronicsCore"),
        .target(name: "FloeElectronicsUI", dependencies: ["FloeElectronicsCore"]),
        .testTarget(name: "FloeElectronicsCoreTests", dependencies: ["FloeElectronicsCore"]),
        .testTarget(name: "FloeElectronicsUITests", dependencies: ["FloeElectronicsUI"])
    ]
)

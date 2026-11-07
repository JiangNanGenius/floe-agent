// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

let package = Package(
    name: "FloeElectronicsKit",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "FloeElectronicsCore", targets: ["FloeElectronicsCore"])],
    targets: [
        .target(name: "FloeElectronicsCore"),
        .testTarget(name: "FloeElectronicsCoreTests", dependencies: ["FloeElectronicsCore"])
    ]
)

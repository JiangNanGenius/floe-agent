// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
// Production package template for the five reviewed HostBridge adapters.
// Copy to FloeAgent/Modules/FloeGameWorkspaceHost/Package.swift.
import PackageDescription
let package = Package(
    name: "FloeGameWorkspaceHost",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeGameWorkspaceHost", targets: ["FloeGameWorkspaceHost"])],
    dependencies: [
        .package(name: "FloeAgent", path: "../.."),
        .package(name: "FloeGameKit", path: "../FloeGameKit"),
        .package(name: "FloeGameAuthoringKit", path: "../FloeGameAuthoringKit"),
        .package(name: "FloeGameEditingKit", path: "../FloeGameEditingKit"),
        .package(name: "FloeGameIDEBridge", path: "../FloeGameIDEBridge"),
        .package(name: "FloeGameRunKit", path: "../FloeGameRunKit")
    ],
    targets: [
        .target(name: "FloeGameWorkspaceHost", dependencies: [
            .product(name: "FloeGameWebKit", package: "FloeGameKit"),
            .product(name: "FloeGameCore", package: "FloeGameKit"),
            .product(name: "FloeGameAuthoring", package: "FloeGameAuthoringKit"),
            .product(name: "FloeGameEditingCore", package: "FloeGameEditingKit"),
            .product(name: "FloeGameIDEBridge", package: "FloeGameIDEBridge"),
            .product(name: "FloeGameRunKit", package: "FloeGameRunKit"),
            .product(name: "FloeCore", package: "FloeAgent"),
            .product(name: "FloeWorkspace", package: "FloeAgent"),
            .product(name: "FloeGit", package: "FloeAgent")
        ])
    ],
    swiftLanguageModes: [.v6]
)

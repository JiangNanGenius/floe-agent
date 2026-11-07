// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

let package = Package(
    name: "FloeHeavyEditorSupport", platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeHeavyEditorSupport", targets: ["FloeHeavyEditorSupport"])],
    targets: [
        .target(name: "FloeHeavyEditorSupport"),
        .testTarget(name: "FloeHeavyEditorSupportTests", dependencies: ["FloeHeavyEditorSupport"])
    ], swiftLanguageModes: [.v6]
)

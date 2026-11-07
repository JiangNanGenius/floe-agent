// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription
let package = Package(name: "FloeGISKit", platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeGISKit", targets: ["FloeGISKit"])],
    dependencies: [.package(path: "../FloeHeavyEditorSupport")],
    targets: [.target(name: "FloeGISKit", dependencies: ["FloeHeavyEditorSupport"], resources: [.copy("Resources/Web")])],
    swiftLanguageModes: [.v6])

// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

let package = Package(
    name: "FloePrintKit",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "FloePrintCore", targets: ["FloePrintCore"])],
    targets: [
        .target(name: "FloePrintCore"),
        .testTarget(name: "FloePrintCoreTests", dependencies: ["FloePrintCore"], resources: [.copy("Fixtures")])
    ]
)

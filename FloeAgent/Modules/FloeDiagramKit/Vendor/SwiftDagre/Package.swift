// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SwiftDagre",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .macCatalyst(.v15)
    ],
    products: [
        .library(name: "SwiftDagre", targets: ["SwiftDagre"]),
    ],
    targets: [
        .target(name: "SwiftDagre"),
        .testTarget(name: "SwiftDagreTests", dependencies: ["SwiftDagre"]),
    ]
)

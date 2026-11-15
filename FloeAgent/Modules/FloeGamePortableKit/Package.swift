// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Independent predevelopment package. It depends only on the reviewed
// FloeGameCore types and intentionally contains no App/WebKit/UI wiring.
let package = Package(
    name: "FloeGamePortableKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGamePortableKit", targets: ["FloeGamePortableKit"]),
        .executable(name: "floe-game-portable", targets: ["GamePortableCLI"])
    ],
    dependencies: [
        .package(name: "FloeGameKit", path: "../FloeGameKit"),
        .package(name: "FloeGameTouchKit", path: "../FloeGameTouchKit")
    ],
    targets: [
        .target(
            name: "FloeGamePortableKit",
            dependencies: [.product(name: "FloeGameCore", package: "FloeGameKit"),
                           .product(name: "FloeGameTouch", package: "FloeGameTouchKit")],
            resources: [
                .copy("Resources/Templates"),
                .copy("Resources/Overlays"),
                .copy("Resources/Manifests")
            ]
        ),
        .executableTarget(name: "GamePortableCLI", dependencies: ["FloeGamePortableKit"]),
        .testTarget(name: "FloeGamePortableKitTests", dependencies: [
            "FloeGamePortableKit",
            .product(name: "FloeGameCore", package: "FloeGameKit")
        ])
    ],
    swiftLanguageModes: [.v6]
)

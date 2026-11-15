// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Independent predevelopment package for narrative and fantasy-console engine
// adapters. Production App wiring stays with the host; FloeGameKit is consumed
// as a plain local package dependency (Core + WebKit products only).
let package = Package(
    name: "FloeGameNarrativeKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameNarrativeKit", targets: ["FloeGameNarrativeKit"]),
        .executable(name: "narrative-fixtures", targets: ["NarrativeFixtures"])
    ],
    dependencies: [
        .package(path: "../FloeGameKit"),
        .package(path: "../FloeGameTouchKit")
    ],
    targets: [
        .target(
            name: "FloeGameNarrativeKit",
            dependencies: [
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameWebKit", package: "FloeGameKit"),
                .product(name: "FloeGameTouch", package: "FloeGameTouchKit")
            ],
            resources: [
                .process("Resources/MPL-2.0.txt"),
                .copy("Resources/Support"),
                .copy("Resources/Shells")
            ]
        ),
        .executableTarget(
            name: "NarrativeFixtures",
            dependencies: ["FloeGameNarrativeKit",
                           .product(name: "FloeGameCore", package: "FloeGameKit")]
        ),
        .testTarget(
            name: "FloeGameNarrativeKitTests",
            dependencies: ["FloeGameNarrativeKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)

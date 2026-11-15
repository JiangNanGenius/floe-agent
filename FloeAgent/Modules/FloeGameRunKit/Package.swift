// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Independent predevelopment package. It composes the reviewed engine adapters
// into one run preparer and adds no App, UI, WebKit-owner or process execution
// code. Canonical placement is a sibling of FloeGameKit and the other Floe game
// packages; `tools/link_dev_packages.py` creates the same sibling names for a
// read-only development build against the frozen PackagedGraph.
let package = Package(
    name: "FloeGameRunKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameRunKit", targets: ["FloeGameRunKit"])
    ],
    dependencies: [
        .package(name: "FloeGameKit", path: "../FloeGameKit"),
        .package(name: "FloeGamePortableKit", path: "../FloeGamePortableKit"),
        .package(name: "FloeGameNarrativeKit", path: "../FloeGameNarrativeKit"),
        .package(name: "FloeGameGDevelopKit", path: "../FloeGameGDevelopKit"),
        .package(name: "FloeGameRuntimeKit", path: "../FloeGameRuntimeKit")
    ],
    targets: [
        .target(
            name: "FloeGameRunKit",
            dependencies: [
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameWebKit", package: "FloeGameKit"),
                .product(name: "FloeGamePortableKit", package: "FloeGamePortableKit"),
                .product(name: "FloeGameNarrativeKit", package: "FloeGameNarrativeKit"),
                .product(name: "FloeGameGDevelopKit", package: "FloeGameGDevelopKit"),
                .product(name: "FloeGameRuntime", package: "FloeGameRuntimeKit")
            ]
        ),
        .testTarget(
            name: "FloeGameRunKitTests",
            dependencies: [
                "FloeGameRunKit",
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameWebKit", package: "FloeGameKit"),
                .product(name: "FloeGamePortableKit", package: "FloeGamePortableKit")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)

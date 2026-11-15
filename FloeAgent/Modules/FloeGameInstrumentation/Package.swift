// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Isolated source package for the Unity/Godot project-side developer hook
// installers. It composes the frozen predevelopment SDK and copies only the
// four reviewed MPL-2.0 template files into its own resource bundle.
let package = Package(
    name: "FloeGameInstrumentation",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameInstrumentation", targets: ["FloeGameInstrumentation"])
    ],
    dependencies: [
        .package(name: "FloeGameKit", path: "../FloeGameKit"),
        .package(name: "FloeGameAuthoringKit", path: "../FloeGameAuthoringKit"),
        .package(name: "FloeGameDeveloperKit", path: "../FloeGameDeveloperKit")
    ],
    targets: [
        .target(
            name: "FloeGameInstrumentation",
            dependencies: [
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameAuthoring", package: "FloeGameAuthoringKit"),
                .product(name: "FloeGameDeveloperCore", package: "FloeGameDeveloperKit")
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "FloeGameInstrumentationTests",
            dependencies: [
                "FloeGameInstrumentation",
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameAuthoring", package: "FloeGameAuthoringKit"),
                .product(name: "FloeGameDeveloperCore", package: "FloeGameDeveloperKit")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Independent GDevelop exchange/export component. It reuses the reviewed
// FloeGameCore project/artifact contracts and FloeGameBuildKit's typed host
// command/port, and adds no executor of its own. App wiring, environment
// selection, jobs, signing and UI acceptance stay with the host.
let package = Package(
    name: "FloeGameGDevelopKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameGDevelopKit", targets: ["FloeGameGDevelopKit"]),
        .executable(name: "floe-gdevelop-export", targets: ["GameGDevelopExportCLI"])
    ],
    dependencies: [
        .package(name: "FloeGameKit", path: "../FloeGameKit"),
        .package(name: "FloeGameBuildKit", path: "../FloeGameBuildKit")
    ],
    targets: [
        .target(
            name: "FloeGameGDevelopKit",
            dependencies: [
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "FloeGameBuildKit", package: "FloeGameBuildKit")
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "GameGDevelopExportCLI",
            dependencies: ["FloeGameGDevelopKit"]
        ),
        .testTarget(
            name: "FloeGameGDevelopKitTests",
            dependencies: ["FloeGameGDevelopKit"],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)

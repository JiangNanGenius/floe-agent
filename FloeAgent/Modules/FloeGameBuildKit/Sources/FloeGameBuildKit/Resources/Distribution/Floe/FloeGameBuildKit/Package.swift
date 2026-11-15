// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Independent predevelopment exchange/build package. Depends only on the
// reviewed FloeGameCore component package and the reviewed vendored
// ZIPFoundation copy (MIT, weichsel/ZIPFoundation 0.9.20 line). App
// integration, environment types and release wiring stay with the host.
let package = Package(
    name: "FloeGameBuildKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeGameBuildKit", targets: ["FloeGameBuildKit"]),
        .executable(name: "floe-game-build-export", targets: ["GameBuildExport"])
    ],
    dependencies: [
        .package(name: "FloeGameKit", path: "../FloeGameKit"),
        .package(name: "ZIPFoundation", path: "../FloeDiagramKit/Vendor/ZIPFoundation")
    ],
    targets: [
        .executableTarget(
            name: "GameBuildExport",
            dependencies: ["FloeGameBuildKit"]
        ),
        .target(
            name: "FloeGameBuildKit",
            dependencies: [
                .product(name: "FloeGameCore", package: "FloeGameKit"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "FloeGameBuildKitTests",
            dependencies: ["FloeGameBuildKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)

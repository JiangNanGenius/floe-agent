// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Independent predevelopment package: RPG Maker XP/VX/VX Ace/MV/MZ data
// adapters (Ruby Marshal data graphs, script archives, database/map/event
// access) over the shared GameKit repository. App integration is deliberately
// separate (coordinator-owned).
let package = Package(
    name: "FloeRPGProjectKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeRPGCore", targets: ["FloeRPGCore"])
    ],
    dependencies: [
        .package(path: "../FloeGameKit"),
        .package(path: "../FloeGameEditingKit")
    ],
    targets: [
        .target(name: "FloeRPGCore", dependencies: [
            .product(name: "FloeGameCore", package: "FloeGameKit"),
            .product(name: "FloeGameEditingCore", package: "FloeGameEditingKit")
        ]),
        .testTarget(name: "FloeRPGCoreTests", dependencies: ["FloeRPGCore"],
                    resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)

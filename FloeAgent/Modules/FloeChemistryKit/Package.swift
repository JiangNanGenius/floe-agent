// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeChemistryKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeChemistryCore", targets: ["FloeChemistryCore"]),
        .library(name: "FloeChemistryEngine", targets: ["FloeChemistryEngine"]),
        .library(name: "FloeChemistryUI", targets: ["FloeChemistryUI"])
    ],
    dependencies: [.package(path: "../FloeChemistryNative"), .package(path: "../FloeChemistrySketch")],
    targets: [
        .target(name: "FloeChemistryCore"),
        .target(name: "FloeChemistryEngine", dependencies: ["FloeChemistryCore", .product(name: "FloeChemistryNative", package: "FloeChemistryNative")]),
        .target(name: "FloeChemistryUI", dependencies: ["FloeChemistryCore", "FloeChemistryEngine", .product(name: "FloeChemistrySketch", package: "FloeChemistrySketch")]),
        .testTarget(name: "FloeChemistryCoreTests", dependencies: ["FloeChemistryCore"]),
        .testTarget(name: "FloeChemistryEngineTests", dependencies: ["FloeChemistryEngine"])
    ],
    swiftLanguageModes: [.v6]
)

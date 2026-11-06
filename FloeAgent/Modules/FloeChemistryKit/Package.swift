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
        .target(name: "FloeChemistryWorkerResources", path: "Backends",
            exclude: ["test_worker.py", "test_science_worker.py", "test_quantum_worker.py", "test_protocol.py", "verify_resources.py"],
            sources: ["WorkerResources.swift"],
            resources: [.copy("chemistry_worker.py"), .copy("science_worker.py"), .copy("quantum_worker.py"),
                        .copy("requirements-rdkit.txt"), .copy("requirements-science.txt"), .copy("WorkerManifest.json")]),
        .target(name: "FloeChemistryEngine", dependencies: ["FloeChemistryCore", "FloeChemistryWorkerResources", .product(name: "FloeChemistryNative", package: "FloeChemistryNative")]),
        .target(name: "FloeChemistryUI", dependencies: ["FloeChemistryCore", "FloeChemistryEngine", .product(name: "FloeChemistrySketch", package: "FloeChemistrySketch")]),
        .testTarget(name: "FloeChemistryCoreTests", dependencies: ["FloeChemistryCore"]),
        .testTarget(name: "FloeChemistryEngineTests", dependencies: ["FloeChemistryEngine"])
    ],
    swiftLanguageModes: [.v6]
)

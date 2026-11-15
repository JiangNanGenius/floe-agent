// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeInteriorKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeInteriorCore", targets: ["FloeInteriorCore"]),
        .library(name: "FloeBuildingRecords", targets: ["FloeBuildingRecords"]),
        .library(name: "FloeBuildingSystems", targets: ["FloeBuildingSystems"]),
        .library(name: "FloeBuildingAnalysis", targets: ["FloeBuildingAnalysis"]),
        .library(name: "FloeBuildingWorkspace", targets: ["FloeBuildingWorkspace"]),
        .library(name: "FloeBuildingUI", targets: ["FloeBuildingUI"]),
        .library(name: "FloeBuildingAssets", targets: ["FloeBuildingAssets"]),
        .library(name: "FloeBuildingProject", targets: ["FloeBuildingProject"]),
        .library(name: "FloeBuildingCAD", targets: ["FloeBuildingCAD"]),
        .library(name: "FloeBuildingEditor", targets: ["FloeBuildingEditor"]),
        .library(name: "FloeBuildingResources", targets: ["FloeBuildingResources"]),
        .executable(name: "InteriorResearchFixture", targets: ["InteriorResearchFixture"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.8.0"),
        .package(path: "../../ThirdParty/FloeCADKit")
    ],
    targets: [
        .target(name: "FloeInteriorCore"),
        .target(name: "FloeBuildingRecords", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], exclude: ["README.md"]),
        .target(name: "FloeBuildingSystems"),
        .target(name: "FloeBuildingAnalysis"),
        .target(name: "FloeBuildingWorkspace", dependencies: ["FloeInteriorCore", "FloeBuildingRecords", "FloeBuildingSystems", "FloeBuildingAnalysis"]),
        .target(name: "FloeBuildingUI", dependencies: ["FloeBuildingWorkspace", "FloeInteriorCore", "FloeBuildingRecords", "FloeBuildingSystems", "FloeBuildingAnalysis"]),
        .target(name: "FloeBuildingAssets", dependencies: ["FloeInteriorCore"]),
        .target(name: "FloeBuildingProject", dependencies: ["FloeInteriorCore", "FloeBuildingRecords"]),
        .target(name: "FloeBuildingCAD", dependencies: ["FloeInteriorCore",
            .product(name: "FloeCAD", package: "FloeCADKit", condition: .when(platforms: [.iOS]))]),
        .target(name: "FloeBuildingEditor", dependencies: ["FloeInteriorCore", "FloeBuildingRecords", "FloeBuildingWorkspace",
            "FloeBuildingUI", "FloeBuildingAssets", "FloeBuildingProject", "FloeBuildingCAD", "FloeBuildingResources",
            .product(name: "FloeCAD", package: "FloeCADKit", condition: .when(platforms: [.iOS]))]),
        .target(name: "FloeBuildingResources", resources: [.copy("Resources")]),
        .executableTarget(name: "InteriorResearchFixture", dependencies: ["FloeInteriorCore"]),
        .testTarget(name: "FloeInteriorCoreTests", dependencies: ["FloeInteriorCore"]),
        .testTarget(name: "FloeBuildingRecordsTests", dependencies: ["FloeBuildingRecords"]),
        .testTarget(name: "FloeBuildingSystemsTests", dependencies: ["FloeBuildingSystems"]),
        .testTarget(name: "FloeBuildingAnalysisTests", dependencies: ["FloeBuildingAnalysis"]),
        .testTarget(name: "FloeBuildingWorkspaceTests", dependencies: ["FloeBuildingWorkspace", "FloeBuildingRecords"]),
        .testTarget(name: "FloeBuildingUITests", dependencies: ["FloeBuildingUI", "FloeBuildingWorkspace", "FloeBuildingRecords"]),
        .testTarget(name: "FloeBuildingAssetsTests", dependencies: ["FloeBuildingAssets", "FloeInteriorCore"]),
        .testTarget(name: "FloeBuildingProjectTests", dependencies: ["FloeBuildingProject", "FloeBuildingRecords"]),
        .testTarget(name: "FloeBuildingCADTests", dependencies: ["FloeBuildingCAD", "FloeInteriorCore", "FloeBuildingResources",
            .product(name: "FloeCAD", package: "FloeCADKit", condition: .when(platforms: [.iOS]))]),
        .testTarget(name: "FloeBuildingEditorTests", dependencies: ["FloeBuildingEditor", "FloeBuildingCAD", "FloeBuildingProject", "FloeBuildingRecords",
            "FloeBuildingWorkspace", "FloeBuildingUI", "FloeBuildingAssets", "FloeInteriorCore",
            .product(name: "FloeCAD", package: "FloeCADKit", condition: .when(platforms: [.iOS]))])
    ]
)

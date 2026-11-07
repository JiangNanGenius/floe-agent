// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeSimulationKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeSimulationCore", targets: ["FloeSimulationCore"]),
        .library(name: "FloeSimulationRuntime", targets: ["FloeSimulationRuntime"]),
        .library(name: "FloeSimulationEngineering", targets: ["FloeSimulationEngineering"]),
        .library(name: "FloeSimulationGeometry", targets: ["FloeSimulationGeometry"]),
        .library(name: "FloeSimulationFields", targets: ["FloeSimulationFields"]),
        .library(name: "FloeSimulationPhysics", targets: ["FloeSimulationPhysics"]),
        .library(name: "FloeSimulationAnimation", targets: ["FloeSimulationAnimation"]),
        .library(name: "FloeSimulationUI", targets: ["FloeSimulationUI"]),
        .library(name: "FloeSimulationSamples", targets: ["FloeSimulationSamples"])
    ],
    dependencies: [.package(path: "../FloeManufacturingKit"), .package(path:"../../ThirdParty/FloeCADKit")],
    targets: [
        .target(name: "FloeSimulationCore"),
        .target(name: "FloeSimulationRuntime", dependencies: ["FloeSimulationCore", "FloeSimulationGeometry"]),
        .binaryTarget(name:"FloeMeshingNative",path:"Vendor/FloeMeshingNative.xcframework"),
        .target(name: "FloeSimulationGeometry", dependencies: ["FloeSimulationCore","FloeMeshingNative",.product(name:"FloeOCCTKernel",package:"FloeCADKit",condition:.when(platforms:[.iOS]))],linkerSettings:[.linkedLibrary("c++"),.linkedLibrary("z")]),
        .binaryTarget(name: "FloeFieldsNative", path: "Vendor/FloeFieldsNative.xcframework"),
        .target(name: "FloeSimulationFields", dependencies: ["FloeSimulationCore", "FloeSimulationGeometry", "FloeFieldsNative"], linkerSettings:[.linkedLibrary("c++")]),
        .binaryTarget(name: "FloeRapierNative", path: "Vendor/FloeRapierNative.xcframework"),
        .target(name: "FloeSimulationPhysics", dependencies: ["FloeSimulationCore", "FloeRapierNative"]),
        .target(name: "FloeSimulationAnimation", dependencies: ["FloeSimulationCore"]),
        .target(name: "FloeSimulationUI", dependencies: ["FloeSimulationCore", "FloeSimulationRuntime", "FloeSimulationGeometry", "FloeSimulationPhysics", "FloeSimulationAnimation", "FloeSimulationEngineering", "FloeSimulationFields"]),
        .target(name: "FloeSimulationSamples", dependencies: ["FloeSimulationCore", "FloeSimulationRuntime", "FloeSimulationGeometry", "FloeSimulationEngineering", "FloeSimulationPhysics"], path:"Samples"),
        .target(name: "FloeSimulationEngineering", dependencies: ["FloeSimulationCore", .product(name: "FloeEngineeringCore", package: "FloeManufacturingKit")]),
        .testTarget(name: "FloeSimulationCoreTests", dependencies: ["FloeSimulationCore"]),
        .testTarget(name: "FloeSimulationIntegrationTests", dependencies: ["FloeSimulationCore", "FloeSimulationRuntime", "FloeSimulationPhysics", "FloeSimulationAnimation", "FloeSimulationEngineering", "FloeSimulationGeometry", "FloeSimulationFields", "FloeSimulationUI"])
    ],
    swiftLanguageModes: [.v6]
)

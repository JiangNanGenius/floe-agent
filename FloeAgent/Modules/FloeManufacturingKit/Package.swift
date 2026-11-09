// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeManufacturingKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeNCProgram", targets: ["FloeNCProgram"]),
        .library(name: "FloeManufacturingNC", targets: ["FloeManufacturingNC"]),
        .library(name: "FloeEngineeringCore", targets: ["FloeEngineeringCore"]),
        .library(name: "FloeManufacturingParameters", targets: ["FloeManufacturingParameters"]),
        .library(name: "FloeManufacturingCore", targets: ["FloeManufacturingCore"]),
        .library(name: "FloeManufacturingUI", targets: ["FloeManufacturingUI"]),
        .executable(name: "manufacturing-qualify", targets: ["ManufacturingQualify"])
    ],
    targets: [
        .target(name: "FloeNCProgram"),
        .target(name: "FloeManufacturingNC", dependencies: ["FloeManufacturingCore", "FloeNCProgram"]),
        .testTarget(name: "FloeNCProgramTests", dependencies: ["FloeNCProgram"]),
        .target(name: "FloeModalLAPACK", publicHeadersPath: "include",
                cSettings: [.define("ACCELERATE_NEW_LAPACK"), .define("ACCELERATE_LAPACK_ILP64")],
                linkerSettings: [.linkedFramework("Accelerate")]),
        .target(name: "FloeEngineeringCore", dependencies: ["FloeModalLAPACK"]),
        .target(name: "TurningNative", publicHeadersPath: "include",
                cxxSettings: [.headerSearchPath("."), .headerSearchPath("Vendor")]),
        .binaryTarget(name: "FloeMachiningNative", path: "Vendor/FloeMachiningNative.xcframework"),
        .target(name: "FloeManufacturingParameters"),
        .target(name: "FloeManufacturingCore", dependencies: ["TurningNative", "FloeMachiningNative", "FloeManufacturingParameters", "FloeEngineeringCore"]),
        .target(name: "FloeManufacturingUI", dependencies: ["FloeManufacturingCore", "FloeManufacturingParameters", "FloeEngineeringCore", "FloeNCProgram", "FloeManufacturingNC"]),
        .executableTarget(name: "ManufacturingQualify", dependencies: ["FloeManufacturingCore", "FloeManufacturingParameters", "FloeEngineeringCore", "FloeNCProgram", "FloeManufacturingNC"]),
        .testTarget(name: "FloeEngineeringCoreTests", dependencies: ["FloeEngineeringCore"]),
        .testTarget(name: "FloeManufacturingTests", dependencies: ["FloeManufacturingCore", "FloeManufacturingParameters", "FloeManufacturingNC", "FloeNCProgram"],resources:[.copy("Fixtures")]),
        .testTarget(name: "FloeManufacturingParametersTests", dependencies: ["FloeManufacturingParameters"])
    ],
    cxxLanguageStandard: .cxx17
)

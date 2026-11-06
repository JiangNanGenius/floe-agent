// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "FloeChemistryNative",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeChemistryNative", targets: ["FloeChemistryNative"])],
    targets: [
        .binaryTarget(name: "FloeChemistryBridge", path: "Vendor/FloeChemistryBridge.xcframework"),
        .target(name: "FloeChemistryNative", dependencies: ["FloeChemistryBridge"], linkerSettings: [.linkedLibrary("c++")])
    ], swiftLanguageModes: [.v6]
)

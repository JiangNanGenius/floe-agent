// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeChemistrySketch",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeChemistrySketch", targets: ["FloeChemistrySketch"])],
    targets: [.target(name: "FloeChemistrySketch", resources: [.copy("Resources/Ketcher"), .copy("Resources/bridge.js")])],
    swiftLanguageModes: [.v6]
)

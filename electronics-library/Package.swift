// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FloeElectronicsLibraryProducer", platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../FloeAgent/Modules/FloeElectronicsKit")],
    targets: [.executableTarget(name: "ElectronicsLibraryProducer", dependencies: [.product(name: "FloeElectronicsCore", package: "FloeElectronicsKit")], path: "tools/Producer")])

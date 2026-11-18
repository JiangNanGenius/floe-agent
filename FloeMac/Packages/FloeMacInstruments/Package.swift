// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeMacInstruments",
    platforms: [.macOS(.v15)],
    products: [.library(name: "FloeMacInstruments", targets: ["FloeMacInstruments"])],
    dependencies: [.package(path: "../../../FloeAgent/Modules/FloeToolbox")],
    targets: [
        .target(name: "FloeMacInstruments", dependencies: [
            .product(name: "FloeToolboxCore", package: "FloeToolbox"),
            .product(name: "FloeToolboxUtilities", package: "FloeToolbox"),
        ]),
        .testTarget(name: "FloeMacInstrumentsTests", dependencies: [
            "FloeMacInstruments",
            .product(name: "FloeToolboxCore", package: "FloeToolbox"),
            .product(name: "FloeToolboxUtilities", package: "FloeToolbox"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)

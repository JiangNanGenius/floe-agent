// swift-tools-version: 6.2
import PackageDescription

// Candidate-only package. It consumes the existing FloeToolbox Swift package
// read-only and never modifies the shared FloeMac host or FloeAgent sources.
let package = Package(
    name: "FloeMacToolbox",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FloeMacToolbox", targets: ["FloeMacToolbox"]),
    ],
    dependencies: [
        .package(path: "../../../FloeAgent/Modules/FloeToolbox"),
        .package(name: "FloeMacToolboxMedia", path: "../FloeMacToolboxMedia"),
        .package(name: "FloeMacInstruments", path: "../FloeMacInstruments"),
        .package(name: "FloeMacNetwork", path: "../FloeMacNetwork"),
        .package(name: "FloeMacTerminal", path: "../FloeMacTerminal"),
        .package(name: "FloeMacVNC", path: "../FloeMacVNC"),
    ],
    targets: [
        .target(
            name: "FloeMacToolbox",
            dependencies: [
                .product(name: "FloeToolboxCore", package: "FloeToolbox"),
                .product(name: "FloeToolboxClients", package: "FloeToolbox"),
                .product(name: "FloeToolboxUI", package: "FloeToolbox"),
                .product(name: "FloeToolboxUtilities", package: "FloeToolbox"),
                .product(name: "FloeToolboxWorkbenches", package: "FloeToolbox"),
                .product(name: "FloeMacMediaSystem", package: "FloeMacToolboxMedia"),
                .product(name: "FloeMacMediaUI", package: "FloeMacToolboxMedia"),
                .product(name: "FloeMacInstruments", package: "FloeMacInstruments"),
                .product(name: "FloeMacNetwork", package: "FloeMacNetwork"),
                .product(name: "FloeMacTerminal", package: "FloeMacTerminal"),
                .product(name: "FloeMacVNC", package: "FloeMacVNC"),
            ]
        ),
        .testTarget(
            name: "FloeMacToolboxTests",
            dependencies: [
                "FloeMacToolbox",
                .product(name: "FloeToolboxCore", package: "FloeToolbox"),
                .product(name: "FloeToolboxClients", package: "FloeToolbox"),
                .product(name: "FloeToolboxUtilities", package: "FloeToolbox"),
                .product(name: "FloeMacMediaSystem", package: "FloeMacToolboxMedia"),
                .product(name: "FloeMacNetwork", package: "FloeMacNetwork"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

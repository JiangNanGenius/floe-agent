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
    ],
    targets: [
        .target(
            name: "FloeMacToolbox",
            dependencies: [
                .product(name: "FloeToolboxCore", package: "FloeToolbox"),
                .product(name: "FloeToolboxUI", package: "FloeToolbox"),
                .product(name: "FloeToolboxUtilities", package: "FloeToolbox"),
                .product(name: "FloeToolboxWorkbenches", package: "FloeToolbox"),
                .product(name: "FloeMacMediaSystem", package: "FloeMacToolboxMedia"),
                .product(name: "FloeMacMediaUI", package: "FloeMacToolboxMedia"),
                .product(name: "FloeMacInstruments", package: "FloeMacInstruments"),
                .product(name: "FloeMacNetwork", package: "FloeMacNetwork"),
            ]
        ),
        .testTarget(
            name: "FloeMacToolboxTests",
            dependencies: [
                "FloeMacToolbox",
                .product(name: "FloeToolboxCore", package: "FloeToolbox"),
                .product(name: "FloeToolboxUtilities", package: "FloeToolbox"),
                .product(name: "FloeMacMediaSystem", package: "FloeMacToolboxMedia"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

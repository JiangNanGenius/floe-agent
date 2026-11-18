// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeMacNetwork",
    platforms: [.macOS(.v15)],
    products: [.library(name: "FloeMacNetwork", targets: ["FloeMacNetwork"])],
    dependencies: [.package(path: "../../../FloeAgent/Modules/FloeToolbox")],
    targets: [
        .target(name: "FloeMacNetwork", dependencies: [
            .product(name: "FloeToolboxCore", package: "FloeToolbox"),
            .product(name: "FloeToolboxClients", package: "FloeToolbox"),
            .product(name: "FloeToolboxDiagnostics", package: "FloeToolbox"),
        ], linkerSettings: [.linkedFramework("CoreWLAN"), .linkedFramework("CoreLocation")]),
        .testTarget(name: "FloeMacNetworkTests", dependencies: [
            "FloeMacNetwork",
            .product(name: "FloeToolboxCore", package: "FloeToolbox"),
            .product(name: "FloeToolboxDiagnostics", package: "FloeToolbox"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)

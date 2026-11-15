// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

let package = Package(
    name: "FloeRPGDeploymentKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeRPGDeployment", targets: ["FloeRPGDeployment"])],
    dependencies: [.package(path: "../FloeGameKit"),
                   .package(path: "../FloeRPGProjectKit")],
    targets: [
        .target(name: "FloeRPGDeployment", dependencies: [.product(name: "FloeGameCore", package: "FloeGameKit")],
                resources: [.process("Resources")]),
        .testTarget(name: "FloeRPGDeploymentTests", dependencies: ["FloeRPGDeployment", .product(name: "FloeRPGCore", package: "FloeRPGProjectKit")], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)

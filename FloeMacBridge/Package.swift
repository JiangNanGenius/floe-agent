// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeMacBridge",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .library(name: "FloeMacBridgeProtocol", targets: ["FloeMacBridgeProtocol"]),
        .executable(name: "FloeMacBridge", targets: ["FloeMacBridgeApp"])
    ],
    targets: [
        .target(name: "FloeMacBridgeProtocol"),
        .target(name: "CBridgePTY", linkerSettings: [.linkedLibrary("util", .when(platforms: [.macOS]))]),
        .executableTarget(name: "FloeMacBridgeApp", dependencies: ["FloeMacBridgeProtocol", "CBridgePTY"]),
        .testTarget(name: "FloeMacBridgeProtocolTests", dependencies: ["FloeMacBridgeProtocol"])
    ]
)

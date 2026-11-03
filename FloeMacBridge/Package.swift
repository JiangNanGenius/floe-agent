// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeMacBridge",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .library(name: "FloeMacBridgeProtocol", targets: ["FloeMacBridgeProtocol"]),
        .executable(name: "FloeMacBridge", targets: ["FloeMacBridgeApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "FloeMacBridgeProtocol"),
        .target(name: "CBridgePTY", linkerSettings: [.linkedLibrary("util", .when(platforms: [.macOS]))]),
        .executableTarget(name: "FloeMacBridgeApp", dependencies: [
            "FloeMacBridgeProtocol", "CBridgePTY",
            .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"], .when(platforms: [.macOS]))]),
        .testTarget(name: "FloeMacBridgeProtocolTests", dependencies: ["FloeMacBridgeProtocol"]),
        .testTarget(name: "FloeMacBridgeAppTests", dependencies: ["FloeMacBridgeApp", "FloeMacBridgeProtocol"])
    ]
)

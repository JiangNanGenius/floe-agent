// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeInteractiveContent",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeInteractiveContentCore", targets: ["FloeInteractiveContentCore"]),
        .library(name: "FloeInteractiveContentWebKit", targets: ["FloeInteractiveContentWebKit"]),
        .executable(name: "floe-interactive-examples", targets: ["InteractiveExamples"])
    ],
    targets: [
        .target(name: "FloeInteractiveContentCore", resources: [.process("Resources")]),
        .target(name: "FloeInteractiveContentWebKit", dependencies: ["FloeInteractiveContentCore"]),
        .executableTarget(name: "InteractiveExamples", dependencies: ["FloeInteractiveContentCore"]),
        .testTarget(name: "FloeInteractiveContentCoreTests", dependencies: ["FloeInteractiveContentCore"]),
        .testTarget(name: "FloeInteractiveContentWebKitTests", dependencies: ["FloeInteractiveContentWebKit"])
    ]
)

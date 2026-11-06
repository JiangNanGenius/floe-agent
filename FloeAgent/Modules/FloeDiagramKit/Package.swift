// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeDiagramKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeDiagramCore", targets: ["FloeDiagramCore"]),
        .library(name: "FloeDiagramIntegration", targets: ["FloeDiagramIntegration"]),
        .library(name: "FloeDiagramLayout", targets: ["FloeDiagramLayout"]),
        .library(name: "FloeDiagramExchange", targets: ["FloeDiagramExchange"]),
        .library(name: "FloeDiagramUI", targets: ["FloeDiagramUI"]),
        .executable(name: "floe-diagram-examples", targets: ["FloeDiagramExamples"])
    ],
    dependencies: [
        .package(name: "SwiftDagre", path: "Vendor/SwiftDagre"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(name: "SwiftMath", path: "Vendor/SwiftMath")
    ],
    targets: [
        .target(name: "FloeDiagramCore"),
        .target(name: "FloeDiagramIntegration", dependencies: ["FloeDiagramCore"]),
        .target(name: "FloeDiagramLayout", dependencies: ["FloeDiagramCore", .product(name: "SwiftDagre", package: "SwiftDagre")]),
        .target(name: "CDiagramCompression", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "FloeDiagramExchange", dependencies: ["FloeDiagramCore", "FloeDiagramLayout", "FloeDiagramIntegration", "CDiagramCompression", .product(name: "ZIPFoundation", package: "ZIPFoundation"), .product(name: "SwiftMath", package: "SwiftMath")]),
        .target(name: "FloeDiagramUI", dependencies: ["FloeDiagramCore", "FloeDiagramLayout", "FloeDiagramIntegration", "FloeDiagramExchange"]),
        .executableTarget(name: "FloeDiagramExamples", dependencies: ["FloeDiagramCore", "FloeDiagramIntegration", "FloeDiagramLayout", "FloeDiagramExchange"]),
        .testTarget(name: "FloeDiagramCoreTests", dependencies: ["FloeDiagramCore"]),
        .testTarget(name: "FloeDiagramIntegrationTests", dependencies: ["FloeDiagramIntegration"]),
        .testTarget(name: "FloeDiagramLayoutTests", dependencies: ["FloeDiagramLayout"]),
        .testTarget(name: "FloeDiagramExchangeTests", dependencies: ["FloeDiagramExchange"])
    ],
    swiftLanguageModes: [.v6]
)

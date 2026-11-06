// swift-tools-version: 6.2
import PackageDescription

// Independent experimental canvas components. Production App integration is separate.
let package = Package(
    name: "FloeCanvasKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeCanvasCore", targets: ["FloeCanvasCore"]),
        .library(name: "FloeCanvasIntegration", targets: ["FloeCanvasIntegration"]),
        .library(name: "FloeCanvasUI", targets: ["FloeCanvasUI"]),
        .library(name: "FloeCanvasFlow", targets: ["FloeCanvasFlow"]),
        .library(name: "FloeCanvasLayout", targets: ["FloeCanvasLayout"]),
        .library(name: "FloeCanvasExchange", targets: ["FloeCanvasExchange"]),
        .executable(name: "floe-canvas-examples", targets: ["FloeCanvasExamples"])
    ],
    dependencies: [
        .package(name: "FloeDiagramKit", path: "../FloeDiagramKit"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(name: "FloeCanvasCore"),
        .target(name: "FloeCanvasIntegration", dependencies: ["FloeCanvasCore"]),
        .target(name: "FloeCanvasUI", dependencies: [
            "FloeCanvasCore", "FloeCanvasIntegration", "FloeCanvasLayout", "FloeCanvasFlow",
            .product(name: "FloeDiagramCore", package: "FloeDiagramKit"),
            .product(name: "FloeDiagramLayout", package: "FloeDiagramKit"),
            .product(name: "FloeDiagramExchange", package: "FloeDiagramKit")
        ]),
        .testTarget(name: "FloeCanvasUITests", dependencies: [
            "FloeCanvasCore", "FloeCanvasIntegration", "FloeCanvasLayout", "FloeCanvasFlow", "FloeCanvasUI",
            .product(name: "FloeDiagramCore", package: "FloeDiagramKit")
        ]),
        .target(name: "FloeCanvasFlow", dependencies: ["FloeCanvasCore", "FloeCanvasIntegration"]),
        .testTarget(name: "FloeCanvasFlowTests", dependencies: ["FloeCanvasCore", "FloeCanvasIntegration", "FloeCanvasFlow"]),
        .target(name: "FloeCanvasLayout", dependencies: [
            "FloeCanvasCore",
            .product(name: "FloeDiagramCore", package: "FloeDiagramKit"),
            .product(name: "FloeDiagramLayout", package: "FloeDiagramKit")
        ]),
        .target(name: "FloeCanvasExchange", dependencies: [
            "FloeCanvasCore", "FloeCanvasIntegration",
            .product(name: "FloeDiagramCore", package: "FloeDiagramKit"),
            .product(name: "FloeDiagramExchange", package: "FloeDiagramKit"),
            .product(name: "FloeDiagramIntegration", package: "FloeDiagramKit"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation")
        ]),
        .testTarget(name: "FloeCanvasLayoutTests", dependencies: ["FloeCanvasCore", "FloeCanvasLayout", .product(name: "FloeDiagramCore", package: "FloeDiagramKit")]),
        .testTarget(name: "FloeCanvasExchangeTests", dependencies: ["FloeCanvasCore", "FloeCanvasIntegration", "FloeCanvasExchange"]),
        .executableTarget(
            name: "FloeCanvasExamples",
            dependencies: ["FloeCanvasCore", "FloeCanvasIntegration", "FloeCanvasFlow", "FloeCanvasLayout", "FloeCanvasExchange", .product(name: "FloeDiagramCore", package: "FloeDiagramKit")],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "FloeCanvasCoreTests", dependencies: ["FloeCanvasCore"]),
        .testTarget(
            name: "FloeCanvasIntegrationTests",
            dependencies: ["FloeCanvasCore", "FloeCanvasIntegration"]
        )
    ],
    swiftLanguageModes: [.v6]
)

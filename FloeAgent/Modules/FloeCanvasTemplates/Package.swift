// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "FloeCanvasTemplates",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeCanvasTemplates", targets: ["FloeCanvasTemplates"]),
        .library(name: "FloeCanvasTemplatesUI", targets: ["FloeCanvasTemplatesUI"])
    ],
    dependencies: [.package(path: "../FloeCanvasKit")],
    targets: [
        .target(name: "FloeCanvasTemplates", dependencies: [
            .product(name: "FloeCanvasCore", package: "FloeCanvasKit"),
            .product(name: "FloeCanvasIntegration", package: "FloeCanvasKit"),
            .product(name: "FloeCanvasFlow", package: "FloeCanvasKit")
        ]),
        .target(name: "FloeCanvasTemplatesUI", dependencies: ["FloeCanvasTemplates"]),
        .testTarget(name: "FloeCanvasTemplatesTests", dependencies: ["FloeCanvasTemplates"])
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FloeNativeCharts",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "FloeNativeChartsCore", targets: ["FloeNativeChartsCore"]),
               .library(name: "FloeNativeChartsUI", targets: ["FloeNativeChartsUI"])],
    targets: [
        .target(name: "FloeNativeChartsCore", path: "Core"),
        .target(name: "FloeNativeChartsUI", dependencies: ["FloeNativeChartsCore"], path: "UI"),
        .testTarget(name: "FloeNativeChartsCoreTests", dependencies: ["FloeNativeChartsCore", "FloeNativeChartsUI"])
    ],
    swiftLanguageModes: [.v6]
)

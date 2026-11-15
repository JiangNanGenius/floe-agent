// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeMoleculePreviewNative",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeMoleculePreviewNative", targets: ["FloeMoleculePreviewNative"])],
    targets: [
        .binaryTarget(name: "FloeMoleculePreviewBridge", path: "Vendor/FloeMoleculePreviewBridge.xcframework"),
        .target(name: "FloeMoleculePreviewNative", dependencies: ["FloeMoleculePreviewBridge"],
                linkerSettings: [.linkedLibrary("c++"), .linkedLibrary("z")]),
        .testTarget(name: "FloeMoleculePreviewNativeTests", dependencies: ["FloeMoleculePreviewNative"])
    ], swiftLanguageModes: [.v6]
)
